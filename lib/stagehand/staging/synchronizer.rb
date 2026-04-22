require 'stagehand/staging/synchronizer/profiler'

module Stagehand
  module Staging
    module Synchronizer
      extend self
      mattr_accessor :schemas_match

      BATCH_SIZE = 1000
      ENTRY_SYNC_ORDER = [:delete, :update, :insert].freeze

      # Immediately sync the changes from the block, preconfirming all changes
      # The block is wrapped in a transaction to prevent changes to records while being synced
      def sync_now!(*args, **opts, &block)
        sync_now(*args, **opts, preconfirmed: true, &block)
      end

      # Immediately attempt to sync the changes from the block if possible
      # The block is wrapped in a transaction to prevent changes to records while being synced
      def sync_now(subject_record = nil, preconfirmed: false, **opts, &block)
        raise SyncBlockRequired unless block_given?

        Profiler.auto_profile('sync_now') do
          Profiler.measure(:sync_now) do
            Rails.logger.info "Syncing Now (preconfirmed: #{preconfirmed})"
            Database.transaction do
              commit = Profiler.measure(:sync_now__commit_capture) { Commit.capture(subject_record, &block) }
              next unless commit # If the commit was empty don't continue
              checklist = Profiler.measure(:sync_now__checklist_build) { Checklist.new(commit.entries) }
              if preconfirmed || !Profiler.measure(:sync_now__requires_confirmation) { checklist.requires_confirmation? }
                sync_checklist(checklist, **opts)
              end
            end
          end
        end
      end

      def auto_sync(polling_delay = 5.seconds, **opts)
        loop do
          Rails.logger.info "Autosyncing"
          sync(BATCH_SIZE, **opts)
          sleep(polling_delay) if polling_delay
        rescue Database::NoRetryError => e
          Rails.logger.info "Autosyncing encountered a NoRetryError"
        end
      end

      def sync(limit = nil, **opts)
        Profiler.auto_profile('sync') do
          Profiler.measure(:sync) do
            synced_count = 0
            deleted_count = 0

            Rails.logger.info "Syncing"

            Database.with_staging_connection do
              iterate_autosyncable_entries do |entry|
                sync_entry(entry, :callbacks => :sync, **opts)
                synced_count += 1

                Profiler.measure(:sync__delete_stale) do
                  scope = CommitEntry.matching(entry).not_in_progress
                  scope = scope.save_operations unless entry.delete_operation?
                  deleted_count += delete_without_range_locks(scope)
                end

                :stop if synced_count == limit
              end
            end

            Rails.logger.info "Synced #{synced_count} entries"
            Rails.logger.info "Removed #{deleted_count} stale entries"

            synced_count
          end
        end
      end

      def sync_all(**opts)
        Profiler.auto_profile('sync_all') do
          Profiler.measure(:sync_all) do
            loop do
              entries = Profiler.measure(:sync_all__load_batch) do
                CommitEntry.order(entry_sync_order_sql).limit(BATCH_SIZE).to_a
              end
              break unless entries.present?

              latest_entries = Profiler.measure(:sync_all__uniq_by_key) { entries.uniq(&:key) }
              latest_entries.each {|entry| sync_entry(entry, :callbacks => :sync, **opts) }
              Rails.logger.info "Synced #{latest_entries.count} entries"

              deleted_count = Profiler.measure(:sync_all__delete_stale) do
                delete_without_range_locks(CommitEntry.matching(latest_entries))
              end
              Rails.logger.info "Removed #{deleted_count - latest_entries.count} stale entries"
            end
          end
        end
      end

      # Copies all the affected records from the staging database to the production database
      def sync_record(record, **opts)
        Profiler.auto_profile('sync_record') do
          checklist = Profiler.measure(:sync_record__checklist_build) { Checklist.new(record) }
          sync_checklist(checklist, **opts)
        end
      end

      def sync_checklist(checklist, **opts)
        Profiler.measure(:sync_checklist) do
          Database.transaction do
            syncing = Profiler.measure(:sync_checklist__syncing_entries) { checklist.syncing_entries }
            subject = Profiler.measure(:sync_checklist__subject_entries) { checklist.subject_entries }
            syncing.each do |entry|
              if subject.include?(entry)
                sync_entry(entry, :callbacks => [:sync, :sync_as_subject], **opts)
              else
                sync_entry(entry, :callbacks => [:sync, :sync_as_affected], **opts)
              end
            end

            Profiler.measure(:sync_checklist__delete_affected) do
              delete_without_range_locks(checklist.affected_entries)
            end
          end
        end
      end

      private

      # Lazily iterate through millions of commit entries
      # Returns commit entries in ID descending order
      def iterate_autosyncable_entries(&block)
        current = CommitEntry.maximum(:id).to_i

        loop do
          entries = Profiler.measure(:iterate__load_batch) do
            autosyncable_entries("id <= #{current}").limit(BATCH_SIZE).order(entry_sync_order_sql).to_a.presence
          end
          break unless entries

          unique = Profiler.measure(:iterate__uniq_by_key) { entries.uniq(&:key) }
          stop_requested = with_confirmed_autosyncability(unique, &block)
          break if stop_requested
          current = entries.last.try(:id).to_i - 1
        end
      end

      # Executes the code in the block if the record referred to by the entry is in fact, autosyncable.
      # This confirmation is used to guard against writes to the record that occur after loading an initial list of
      # entries that are autosyncable, but before the record is actually synced. To prevent this, a lock on the record
      # is acquired and then the record's autosync eligibility is rechecked before calling the block.
      def with_confirmed_autosyncability(entries, &block)
        entries = Array.wrap(entries)
        return false unless entries.present?

        stop_requested = false

        Profiler.measure(:with_confirmed_autosyncability) do
          Database.transaction do
            # Lock the records so nothing can update them after we confirm autosyncability
            Profiler.measure(:acquire_record_locks) { acquire_record_locks(entries) }

            # Execute the block for each entry we've confirm autosyncability
            confirmed_ids = Profiler.measure(:autosyncable_recheck) do
              Set.new(autosyncable_entries.where(:id => entries).pluck(:id))
            end

            entries.each do |entry|
              next unless confirmed_ids.include?(entry.id)

              if block.call(entry) == :stop
                stop_requested = true
                break
              end
            end
          end
        end

        stop_requested
      end

      # Does not actually acquire a lock, instead it triggers a 'first read' so the transaction will ensure subsequent
      # reads of the locked rows return the same value, even if modified outside of the transaction
      def acquire_record_locks(entries)
        entries.each(&:record)
      end

      def autosyncable_entries(scope = nil)
        entries = CommitEntry.content_operations.where(scope)
        if Configuration.ghost_mode?
          entries = entries.not_in_progress
        else
          entries = entries.with_uncontained_keys
        end
        return entries
      end

      def sync_entry(entry, callbacks: false)
        Profiler.measure(:sync_entry) do
          raise SchemaMismatch unless schemas_match?

          run_sync_callbacks(entry, callbacks) do
            next unless entry.content_operation? # Only sync records from content operations because those are the only rows that have changes
            next if Configuration.single_connection? # Avoid deadlocking if the databases are the same. There is nothing to sync because there is only a single database

            Rails.logger.info "Synchronizing #{entry.table_name} #{entry.record_id} (#{entry.operation})"

            if entry.delete_operation?
              Profiler.measure(:sync_entry__production_delete) { Production.delete(entry) }
            elsif entry.save_operation?
              Profiler.measure(:sync_entry__production_save) { Production.save(entry) }
            end

            Rails.logger.info "Synchronized #{entry.table_name} #{entry.record_id} (#{entry.operation})"
          end
        end
      end

      def entry_sync_order_sql
        @entry_sync_order_sql ||= Arel.sql(ActiveRecord::Base.send(:sanitize_sql_for_order, [Arel.sql('FIELD(operation, ?), id ASC'), ENTRY_SYNC_ORDER])).freeze
      end

      def schemas_match?
        return schemas_match unless schemas_match.nil?
        self.schemas_match = Database.staging_database_versions == Database.production_database_versions
        return schemas_match
      end

      def run_sync_callbacks(entry, callbacks, &block)
        Profiler.measure(:run_sync_callbacks) do
          callbacks = Array.wrap(callbacks.presence).dup
          record = Profiler.measure(:run_sync_callbacks__entry_record) { entry.record }
          next block.call unless callbacks.present? && record

          callback_name = callbacks.shift
          # Per-callback-name span: self_cpu here is time spent in Rails'
          # callback dispatch plus the host app's own before/around/after
          # hooks for this callback, excluding the nested recursion (which
          # becomes a child span of its own).
          Profiler.measure(:"sync_callback_dispatch__#{callback_name}") do
            record.run_callbacks(callback_name) do
              run_sync_callbacks(entry, callbacks, &block)
            end
          end
        end
      end

      # Deletes records without acquiring range locks which have a higher likelihood of causing a deadlock.
      # See https://dev.mysql.com/doc/refman/5.6/en/innodb-locks-set.html for info on locks set by SQL statements.
      def delete_without_range_locks(commit_entries)
        Profiler.measure(:delete_without_range_locks) do
          ids = commit_entries.pluck(:id)
          ids.in_groups_of(1000, false) do |batch|
            CommitEntry.delete(batch)
          end

          ids.length
        end
      end
    end
  end

  # EXCEPTIONS

  class SyncBlockRequired < StandardError; end
  class SchemaMismatch < StandardError; end
end

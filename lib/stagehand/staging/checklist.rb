module Stagehand
  module Staging
    class Checklist
      extend Cache
      include Cache

      def self.related_commits(commit)
        Commit.find(related_commit_ids(commit))
      end

      def self.related_commit_ids(commit)
        related_entries(commit.entries).collect(&:commit_id).select(&:present?).uniq
      end

      def self.related_entries(entries, relation_filter = nil)
        entries = Array.wrap(entries)
        related_entries = []

        entries_to_spider = Array.wrap(entries)
        while entries_to_spider.present?
          committed_matching = CommitEntry.committed.matching(entries_to_spider)
          committed_matching = committed_matching.where(id: committed_matching.select(&relation_filter)) if relation_filter

          matching_commit_entries = CommitEntry.where(:commit_id => committed_matching.select(:commit_id))

          # Spider using content operations. Don't spider control operations to avoid extending the list of results unnecessarily
          content_operations, control_operations = matching_commit_entries.partition(&:content_operation?)
          entries_to_spider = content_operations - related_entries

          # Record the spidered entries and the control entries
          related_entries.concat(entries_to_spider)
          related_entries.concat(control_operations)
        end

        # Also include uncontained commit entries that matched
        related_entries.concat(CommitEntry.uncontained.matching(entries + related_entries))
        related_entries.uniq!

        return related_entries
      end

      def self.associated_records(entries, association_filter = nil)
        records = preload_records(compact_entries(entries)).select(&:record).flat_map do |entry|
          associated_associations(entry.record_class).flat_map do |association|
            entry.record.send(association)
          end
        end

        records.uniq!
        records.compact!
        records.select! {|record| stagehand_class?(record.class) }
        records.select!(&association_filter) if association_filter

        return records
      end

      # Returns a list of entries that only includes a single entry for each record.
      # The entries are prioritized by the list of operations as given by `:priority`.
      def self.compact_entries(entries, priority: [:delete, :update, :insert])
        compact_entries = group_entries(entries)
        compact_entries = compact_entries.values_at(*priority).flatten
        compact_entries.uniq!(&:key)

        return compact_entries
      end

      # Groups entries by their operation
      def self.group_entries(entries)
        group_entries = Hash.new {|h,k| h[k] = [] }
        group_entries.merge! entries.group_by(&:operation).symbolize_keys!

        return group_entries
      end

      def self.preload_records(entries)
        entries.group_by(&:table_name).each do |table_name, group_entries|
          klass = CommitEntry.infer_base_class(table_name)
          records = klass.where(:id => group_entries.collect(&:record_id))
          records = records.includes(associated_associations(klass))
          records_by_id = records.collect {|r| [r.id, r] }.to_h
          group_entries.each do |entry|
            entry.record = records_by_id[entry.record_id]
          end
        end

        return entries
      end

      private

      def self.associated_associations(klass)
        cache("#{klass.name}_associated_associations") do
          reflections = klass.reflect_on_all_associations(:belongs_to)

          reflections.select! do |reflection|
            begin
              reflection.respond_to?(:check_preloadable!) ? reflection.check_preloadable! : reflection.check_eager_loadable!
              next true
            rescue ArgumentError
              next false
            end
          end

          reflections.collect(&:name)
        end
      end

      def self.stagehand_class?(klass)
        cache("#{klass.name}_stagehand_class?") { Schema.has_stagehand?(klass.table_name) }
      end

      public

      def initialize(subject, confirmation_filter: Configuration.checklist_confirmation_filter, association_filter: Configuration.checklist_association_filter, relation_filter: Configuration.checklist_relation_filter)
        @subject = subject
        @confirmation_filter = confirmation_filter
        @association_filter = association_filter
        @relation_filter = relation_filter
        affected_entries # Init the affected_entries changes can be rolled back without affecting the checklist
      end

      def confirm_create
        cache(:confirm_create) { grouped_required_confirmation_entries[:insert].collect(&:record) }
      end

      def confirm_delete
        cache(:confirm_delete) { grouped_required_confirmation_entries[:delete].collect(&:record).compact }
      end

      def confirm_update
        cache(:confirm_update) { grouped_required_confirmation_entries[:update].collect(&:record) }
      end

      # Returns true if there are any changes in the checklist that require confirmation
      def requires_confirmation?
        cache(:requires_confirmation?) { grouped_required_confirmation_entries.values.flatten.present? }
      end

      # Returns a list of records that exist in commits where the staging_record is not in the start operation
      def requires_confirmation
        cache(:requires_confirmation) { grouped_required_confirmation_entries.values.flatten.collect(&:record).compact }
      end

      def syncing_entries
        cache(:syncing_entries) { self.class.compact_entries(affected_entries, priority: Synchronizer::ENTRY_SYNC_ORDER) }
      end

      def affected_records
        cache(:affected_records) { affected_entries.uniq(&:key).collect(&:record).compact }
      end

      def affected_entries
        cache(:affected_entries) do
          from_subject = subject_entries
          from_subject |= CommitEntry.where(commit_id: subject_entries.select(:commit_id))
          related = self.class.related_entries(from_subject, @relation_filter)
          associated = self.class.associated_records(related, @association_filter)
          associated_related = self.class.related_entries(associated, @relation_filter)

          (from_subject + related + associated_related).uniq
        end
      end

      def subject_entries
        cache(:subject_entries) { CommitEntry.not_in_progress.matching(@subject) }
      end

      private

      def grouped_required_confirmation_entries
        cache(:grouped_required_confirmation_entries) do
          entries = affected_entries.dup
          subject_entries, subject_records = Array.wrap(@subject).partition {|model| model.is_a?(CommitEntry) }

          # Don't need to confirm entries that were not part of a commit
          entries.select!(&:commit_id)

          # Don't need to confirm entries that exactly match a subject commit entry
          entries -= subject_entries

          # Don't need to confirm entries that match the checklist subject records
          entries.reject! {|entry| entry.matches?(subject_records) }

          # Don't need to confirm entries that are part of a commits whose subject is a checklist subject record
          staging_record_start_operation_ids = affected_entries.select do |entry|
            entry.start_operation? && entry.matches?(subject_records)
          end.collect(&:id)
          entries.reject! {|entry| staging_record_start_operation_ids.include?(entry.commit_id) }

          entries = self.class.compact_entries(entries, priority: [:delete, :insert, :update])
          entries = filter_entries(entries)
          entries = self.class.group_entries(entries)
        end
      end

      def filter_entries(entries)
        return entries unless @confirmation_filter
        return entries.select {|entry| @confirmation_filter.call(entry.record) if entry.record }
      end
    end
  end
end

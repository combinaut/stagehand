describe Stagehand::Staging::Synchronizer do
  let(:source_record) { SourceRecord.create }

  def delete_constrained_records_from_production
    Stagehand::Database
      .with_production_connection { ConstrainedRecord.all.to_a }
      .each {|record| Stagehand::Production.delete(record) }
  end

  describe '::auto_sync' do
    before do
      allow(described_class).to receive(:loop).and_yield.and_yield # Only perform 2 loops for any example
    end

    it 'loops continuously' do
      expect(described_class).to receive(:sync).exactly(:twice)
      described_class.auto_sync
    end

    it 'breaks the loop if sync raises an exception' do
      expect(described_class).to receive(:sync).exactly(:once).and_raise(StandardError)
      expect { described_class.auto_sync }.to raise_exception(StandardError)
    end

    it 'does not break the loop if sync raises a NoRetryError' do
      expect(described_class).to receive(:sync).exactly(:twice).and_raise(Stagehand::Database::NoRetryError)
      described_class.auto_sync
    end
  end

  describe '::sync_record' do
    it 'copies new records to the production database' do
      expect { subject.sync_record(source_record) }.to change { Stagehand::Production.status(source_record) }.to(:not_modified)
    end

    it 'updates existing records in the production database' do
      Stagehand::Production.save(source_record)
      source_record.update_attribute(:updated_at, 10.days.from_now)

      expect { subject.sync_record(source_record) }.to change { Stagehand::Production.status(source_record) }.to(:not_modified)
    end

    it 'deletes deleted records in the production database' do
      Stagehand::Production.save(source_record)
      source_record.destroy
      expect { subject.sync_record(source_record) }.to change { Stagehand::Production.status(source_record) }.to(:new)
    end

    it 'returns the number of records synchronized' do
      Stagehand::Production.save(source_record)
      expect(subject.sync_record(source_record)).to eq(1)
    end

    it 'deletes all control entries for directly related commits' do
      commit = Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      subject.sync_record(source_record)

      expect(commit.entries.reload).to be_blank
    end

    it 'deletes all control entries for indirectly related commits' do
      other_record = SourceRecord.create
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter); other_record.increment!(:counter) }
      commit = Stagehand::Staging::Commit.capture { other_record.increment!(:counter) }
      subject.sync_record(source_record)

      expect(commit.entries.reload).to be_blank
    end

    it 'raises an exception if staging and production schemas are out of sync' do
      subject.schemas_match = nil
      Stagehand::Database.staging_connection.execute('INSERT INTO schema_migrations VALUES (1234)')
      expect { subject.sync_record(source_record) }.to raise_exception(Stagehand::SchemaMismatch)
      Stagehand::Database.staging_connection.execute('DELETE FROM schema_migrations WHERE version = 1234')
      subject.schemas_match = nil
    end

    it 'does not deadlock when used in a transaction and staging and production databases are the same' do
      connection = Stagehand.configuration.staging_connection_name
      with_configuration(:staging_connection_name => connection, :production_connection_name => connection) do
        ActiveRecord::Base.transaction do
          expect { subject.sync_record(source_record) }.not_to raise_exception
        end
      end
    end
  end

  describe '::sync' do
    it 'syncs records with only entries that do not belong to a commit ' do
      source_record.increment!(:counter)
      expect { subject.sync }.to change { Stagehand::Production.status(source_record) }.to(:not_modified)
    end

    it 'does not sync records with entries that belong to a commit' do
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      expect { subject.sync }.not_to change { Stagehand::Production.status(source_record) }
    end

    it 'does not sync records with entries that belong to commits in progress' do
      start_operation = Stagehand::Staging::Commit.capture do
        source_record.increment!(:counter)
        expect { subject.sync }.not_to change { Stagehand::Production.status(source_record) }
      end
    end

    it 'does not sync records with matching entries that belong to commits in progress' do
      skip 'We need to be able to commit the change from the other thread between determining autosyncable entries and deleting the defunct entries, which is not easy to do'
      start_operation = Stagehand::Staging::Commit.capture do
        Thread.new { source_record.increment!(:counter) }.join
        source_record.increment!(:counter)
        expect { subject.sync }.to change { Stagehand::Staging::CommitEntry.matching(source_record).count }.by(-1)
      end
    end

    it 'does not sync records with entries that belong to a commit and also entries that do not' do
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      source_record.increment!(:counter)
      expect { subject.sync }.not_to change { Stagehand::Production.status(source_record) }
    end

    it 'deletes records that have been updated and then deleted on staging' do
      Stagehand::Production.save(source_record)
      source_record.increment!(:counter)
      source_record.delete
      expect { subject.sync }.to change { Stagehand::Production.status(source_record) }.from(:modified).to(:new)
    end

    it 'can sync records that have column values that conflict with a deleted record' do
      delete_constrained_records_from_production
      deleted = ConstrainedRecord.create!(:unique_number => 1)
      Stagehand::Production.save(deleted)
      deleted.delete

      created = ConstrainedRecord.create!(:unique_number => 1)

      expect{ subject.sync }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end

    it 'can sync records that have column values that conflict with an updated record' do
      delete_constrained_records_from_production
      updated = ConstrainedRecord.create!(:unique_number => 1)
      Stagehand::Production.save(updated)
      updated.update!(:unique_number => 2)

      created = ConstrainedRecord.create!(:unique_number => 1)

      expect{ subject.sync }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end

    it 'deletes synced entries' do
      source_record
      commit_entry = Stagehand::Staging::CommitEntry.last
      subject.sync

      expect(commit_entry.class.where(:id => commit_entry)).not_to exist
    end

    it 'deletes stale entries' do
      source_record
      commit_entry = Stagehand::Staging::CommitEntry.last
      source_record.touch
      subject.sync

      expect(commit_entry.class.where(:id => commit_entry)).not_to exist
    end

    it 'does not delete active commit starts where the record is the subject when syncing an entry that is not part of the commit' do
      source_record
      Stagehand::Staging::CommitEntry.last.update_column(:commit_id, nil)
      start_operation = Stagehand::Staging::CommitEntry.start_operations.create(record_id: source_record.id, table_name: source_record.class.table_name)
      subject.sync

      expect(start_operation.class.where(id: start_operation)).to exist
    end

    it 'does not delete active commit starts where the record is the subject when an entry exists that is not part of the commit and came after' do
      source_record
      Stagehand::Staging::CommitEntry.last.delete
      start_operation = Stagehand::Staging::CommitEntry.start_operations.create(record_id: source_record.id, table_name: source_record.class.table_name)
      source_record.touch
      Stagehand::Staging::CommitEntry.last.update_column(:commit_id, nil)
      subject.sync

      expect(start_operation.class.where(id: start_operation)).to exist
    end

    it 'syncs deletion of records with foreign key constraints' do
      constrained_record = nil

      described_class.sync_now do
        constrained_record = ConstrainedRecord.create!(:source_record => source_record)
      end

      constrained_record.destroy
      source_record.destroy

      expect { described_class.sync }.to change { Stagehand::Production.status(constrained_record) }.to(:new)
    end

    it 'does not sync the same record multiple times when multiple commit entries exist for it' do
      source_record.increment!(:counter)
      source_record.increment!(:counter)

      expect(Stagehand::Production).to receive(:save).once
      described_class.sync
    end

    it 'deletes all other commit entries for a record that has been deleted even if those entries are not processed' do
      source_record.increment!(:counter)
      source_record.increment!(:counter)
      source_record.destroy

      expect { described_class.sync(1) }.to change { Stagehand::Staging::CommitEntry.matching(source_record).count }.to 0
    end

    it 'deletes all other create and update commit entries for a record that has been updated even if those entries are not processed' do
      source_record.increment!(:counter)
      source_record.increment!(:counter)
      expect { described_class.sync(1) }.to change { Stagehand::Staging::CommitEntry.matching(source_record).count }.to 0
    end

    it 'does not delete a delete commit entry for a record that is created while the record is being synced' do
      source_record.increment!(:counter)
      expected_scope = Stagehand::Staging::CommitEntry.matching(source_record)

      allow(Stagehand::Staging::CommitEntry).to receive(:matching).and_wrap_original do |original_method, *args, &block|
        source_record.destroy
        original_method.call(*args, &block)
      end

      expect { described_class.sync(1) }.to change { expected_scope.delete_operations.count }.to 1
    end

    it 'stops syncing once the limit has been reached' do
      record_1 = SourceRecord.create
      record_2 = SourceRecord.create

      subject.sync(1)
      statuses = [record_1, record_2].collect {|record| Stagehand::Production.status(record) }

      expect(statuses.count(:not_modified)).to eq(1)
    end

    it 'can handle many autosyncable commit entries from a single table' do
      # Throughput stress test: sync 1000 entries from a 100k-entry backlog,
      # all from the same table. Uses real sandbox records so every sync
      # iteration does the full per-entry work (materialize + write to
      # production + stale-dedup), not just the iteration/dedup loop. Pairs
      # with the alternating-tables variant below — same workload, same
      # budget, only the table-switching dimension differs.
      sync_count = 1000
      backlog = 100_000
      SourceRecord.insert_all(Array.new(sync_count) { { name: 'seed' } })
      source_ids = SourceRecord.order(:id).last(sync_count).pluck(:id)
      Stagehand::Staging::CommitEntry.delete_all # discard any auto-generated entries from the seeding above

      operation = Stagehand::Staging::CommitEntry::INSERT_OPERATION
      unique_entries = source_ids.map do |id|
        { record_id: id, table_name: SourceRecord.table_name, operation: operation }
      end
      # Pad with duplicates so the sync drains a realistic backlog on top of
      # its per-entry work (stale duplicates get cleared out by sync, but
      # they still cost something to iterate past).
      entries = (unique_entries * (backlog.to_f / unique_entries.length).ceil).first(backlog)
      Stagehand::Staging::CommitEntry.insert_all(entries)

      # `samples: 1, warmup: 0` because the first sync drains the queue
      # (stale dedup removes the duplicates), so subsequent samples would
      # see nothing to sync and trivially pass the budget regardless of a
      # regression.
      expect { subject.sync(sync_count) }
        .to take_less_than(10).seconds.over({ samples: 1, warmup: 0, discard_outliers: false })
    end

    it 'can handle many autosyncable commit entries that alternate across tables' do
      # Same workload as the single-table variant (1000 syncs, 100k backlog)
      # so the two are apples-to-apples — the only variable is that entries
      # here alternate between two tables. Every sync iteration swaps
      # `Production::Record.table_name=` *and* materializes an AR row, which
      # is the only combination that stresses `reset_column_information` +
      # lazy schema reload end-to-end. This is where the Rails 7.1+
      # `alias_attribute` duplicate-accumulation regression
      # (https://github.com/rails/rails/issues/57235) would blow up if
      # unpatched — the alias list grows with each table switch and
      # `define_attribute_methods` degrades quadratically. We patch this
      # downstream; the timing budget guards against the regression on all
      # Rails versions, and the alias-count assertion below adds a
      # deterministic guard on Rails 7.1+.
      sync_count = 1000
      backlog = 100_000
      per_table = sync_count / 2
      SourceRecord.insert_all(Array.new(per_table) { { name: 'seed' } })
      TargetAssignment.insert_all(Array.new(per_table) { { target_id: 0 } })
      source_ids = SourceRecord.order(:id).last(per_table).pluck(:id)
      target_ids = TargetAssignment.order(:id).last(per_table).pluck(:id)
      Stagehand::Staging::CommitEntry.delete_all

      operation = Stagehand::Staging::CommitEntry::INSERT_OPERATION
      unique_entries = source_ids.zip(target_ids).flat_map do |source_id, target_id|
        [
          { record_id: source_id, table_name: SourceRecord.table_name, operation: operation },
          { record_id: target_id, table_name: TargetAssignment.table_name, operation: operation }
        ]
      end
      entries = (unique_entries * (backlog.to_f / unique_entries.length).ceil).first(backlog)
      Stagehand::Staging::CommitEntry.insert_all(entries)

      expect { subject.sync(sync_count) }
        .to take_less_than(25).seconds.over({ samples: 1, warmup: 0, discard_outliers: false })

      # Rails 7.0 predates `aliases_by_attribute_name`; on 7.1+ the alias
      # list should never grow past a single entry for `id_value`.
      if ActiveModel::AttributeMethods::ClassMethods.method_defined?(:aliases_by_attribute_name)
        aliases = Stagehand::Production::Record.send(:aliases_by_attribute_name).fetch('id', [])
        expect(aliases.count('id_value')).to eq(1)
      end
    end

    it 'does not raise an exception if there are no records to sync' do
      expect { subject.sync }.not_to raise_exception
    end

    in_ghost_mode do
      it 'syncs records with only entries that do not belong to a commit ' do
        source_record.increment!(:counter)
        expect { subject.sync }.to change { Stagehand::Production.status(source_record) }.to(:not_modified)
      end

      it 'syncs records with entries that belong to a commit' do
        Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
        expect { subject.sync }.to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
      end

      it 'syncs records with entries that belong to a commit and also entries that do not' do
        Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
        source_record.increment!(:counter)
        expect { subject.sync }.to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
      end
    end

    context 'when another connection is writing to records being synced' do
      without_transactional_fixtures

      it 'does not sync the record if an outside write makes a change to the record during the sync' do
        skip 'We need to be able to commit the change from the other thread between determining autosyncable entries and deleting the defunct entries, which is not easy to do'
        # thread 1 initiates sync
        # thread 1 finds list of entries that are autosyncable
        # thread 2 modifies one of the records refered to in the list of entries
        # thread 1 attempts to sync each of the entries in the list

        # expect the changes to the modified record are not synced
      end
    end
  end

  describe '::sync_all' do
    before { Stagehand::Production.save(source_record) }
    after { Stagehand::Production.delete(source_record) }

    it 'syncs records that require confirmation' do
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      expect{ subject.sync_all }.to change { Stagehand::Production.status(source_record) }.from(:modified).to(:not_modified)
    end

    it 'syncs records that do not require confirmation' do
      source_record.increment!(:counter)
      expect{ subject.sync_all }.to change { Stagehand::Production.status(source_record) }.from(:modified).to(:not_modified)
    end

    it 'does not attempt to sync a record twice if it has multiple entries' do
      source_record.increment!(:counter)
      expect(Stagehand::Production).to receive(:save).once
      subject.sync_all
    end

    it 'deletes records that have been modified and then deleted' do
      source_record.increment!(:counter)
      source_record.delete
      expect{ subject.sync_all }.to change { Stagehand::Production.status(source_record) }.from(:modified).to(:new)
    end

    it 'can sync records that have column values that conflict with a deleted record' do
      delete_constrained_records_from_production
      deleted = ConstrainedRecord.create!(:unique_number => 1)
      Stagehand::Production.save(deleted)
      deleted.delete

      created = ConstrainedRecord.create!(:unique_number => 1)

      expect{ subject.sync_all }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end

    it 'can sync records that have column values that conflict with an updated record' do
      delete_constrained_records_from_production
      updated = ConstrainedRecord.create!(:unique_number => 1)
      Stagehand::Production.save(updated)
      updated.update!(:unique_number => 2)

      created = ConstrainedRecord.create!(:unique_number => 1)

      expect{ subject.sync_all }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end
  end

  shared_examples_for 'a sync-now method' do |sync_method|
    it 'requires a block' do
      expect { subject.public_send(sync_method) }.to raise_exception(Stagehand::SyncBlockRequired)
    end

    it 'it syncs changes to a record that has been modified, but only outside of a commit' do
      source_record.increment!(:counter)
      expect { subject.public_send(sync_method) { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
    end

    it 'immediately syncs records modified from within the block if they are not part of an existing commit' do
      expect { subject.public_send(sync_method) { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
    end

    it 'syncs attributes modified from within the block' do
      counter = source_record.counter || 0
      expect { subject.public_send(sync_method) { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.find(source_record) }.to have_attributes(counter: counter + 1)
    end

    it 'does not sync changes to records not modified in the block' do
      other_record = SourceRecord.create
      expect { subject.public_send(sync_method) { source_record.increment!(:counter) } }.not_to change { Stagehand::Production.status(other_record) }
    end

    it 'does not sync anything if nothing was captured during the block' do
      other_record = SourceRecord.create
      expect { subject.public_send(sync_method) { } }.not_to change { Stagehand::Production.status(other_record) }
    end

    it 'does not sync a capture with a subject with uncontained changes if nothing was captured during the block' do
      other_record = SourceRecord.create
      expect { subject.public_send(sync_method, other_record) { } }.not_to change { Stagehand::Production.status(other_record) }
    end

    context 'when multiple connections are accessing a record during the block' do
      without_transactional_fixtures

      let(:thread_1) do
        Thread.new do
          subject.public_send(sync_method) do
            @thread_1_syncing = true
            sleep 0.1 until @thread_1_wake_before_write
            SourceRecord.find(source_record.id).update_columns(:counter => 1)
            @thread_1_done = true
            sleep 0.1 until @thread_1_wake_after_write
          end
        end
      end

      before do
        source_record
        @thread_1_syncing = false
        @thread_1_wake_before_write = false
        @thread_1_wake_after_write = false
        @thread_1_done = false
        thread_1
      end

      it 'syncs outside writes made before writes in the block' do
        sleep 0.1 until @thread_1_syncing

        thread_2 = Thread.new do
          SourceRecord.find(source_record.id).update_columns(:name => 'Bob')
          @thread_1_wake_before_write = true
          @thread_1_wake_after_write = true
        end

        thread_1.join(1) || fail('Timed out waiting for Thread 1')
        thread_2.join(1) || fail('Timed out waiting for Thread 2')

        expect(Stagehand::Production.find(source_record)).to have_attributes(:name => 'Bob')
      end

      it 'does not block external reads of records after they are written to in the block' do
        @thread_1_wake_before_write = true
        sleep 0.1 until @thread_1_done

        thread_2 = Thread.new do
          SourceRecord.find(source_record.id)
          @thread_1_wake_after_write = true
        end

        thread_1.join(1) || fail('Timed out waiting for Thread 1')
        thread_2.join(1) || fail('Timed out waiting for Thread 2')

        # The expectation is omitted because success is simply the absence of a timeout failure
      end

      it 'syncs changes to attributes made from outside the main thread' do
        @thread_1_wake_before_write = true
        @thread_1_wake_after_write = true

        thread_1.join(1) || fail('Timed out waiting for Thread 1')

        expect(Stagehand::Production.find(source_record)).to have_attributes(:counter => 1)
      end

      it 'does not sync outside writes made after writes in the block' do
        @thread_1_wake_before_write = true
        sleep 0.1 until @thread_1_done

        thread_2 = Thread.new do
          SourceRecord.find(source_record.id).update_columns(:name => 'Bob')
        end

        sleep 0.1 until thread_2.status == 'sleep' # NOTE: This condition assumes thread_2 only sleeps while waiting for the lock on source_record
        @thread_1_wake_after_write = true

        thread_1.join(1) || fail('Timed out waiting for Thread 1')
        thread_2.join(1) || fail('Timed out waiting for Thread 2')

        expect(Stagehand::Production.find(source_record)).not_to have_attributes(:name => 'Bob')
      end
    end
  end

  describe '::sync_now' do
    it_behaves_like 'a sync-now method', :sync_now

    it 'does not sync records modified from within the block if unsynced changes to those records exist in a separate commit' do
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      expect { subject.sync_now { source_record.increment!(:counter) } }
        .not_to change { Stagehand::Production.status(source_record) }.from(:new)
    end

    it 'does not sync records modified from within the block if they are the subject of an existing commit' do
      Stagehand::Staging::Commit.capture(source_record) { source_record.increment!(:counter) }
      expect { subject.sync_now { source_record.increment!(:counter) } }
        .not_to change { Stagehand::Production.status(source_record) }
    end

    it 'does not sync records modified from within the block if they are the subject of an existing commit even if they are the subject of the `sync_now`' do
      Stagehand::Staging::Commit.capture(source_record) { source_record.increment!(:counter) }
      expect { subject.sync_now(source_record) { source_record.increment!(:counter) } }
        .not_to change { Stagehand::Production.status(source_record) }
    end
  end

  describe '::sync_now!' do
    it_behaves_like 'a sync-now method', :sync_now!

    it 'syncs records modified from within the block if unsynced changes to those records exist in a separate commit' do
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      expect { subject.sync_now! { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
    end

    it 'syncs records modified from within the block if they are the subject of an existing commit' do
      Stagehand::Staging::Commit.capture(source_record) { source_record.increment!(:counter) }
      expect { subject.sync_now! { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
    end

    it 'syncs records modified from within the block if they are the subject of an existing commit and are the subject of the `sync_now`' do
      Stagehand::Staging::Commit.capture(source_record) { source_record.increment!(:counter) }
      expect { subject.sync_now!(source_record) { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
    end
  end

  describe '::sync_checklist' do
    it 'can sync records that have column values that conflict with a deleted record' do
      delete_constrained_records_from_production
      Stagehand::Staging::Commit.capture do
        deleted = ConstrainedRecord.create!(:unique_number => 1)
        Stagehand::Production.save(deleted)
        deleted.delete
        ConstrainedRecord.create!(:unique_number => 1)
      end

      created = ConstrainedRecord.last
      checklist = Stagehand::Staging::Checklist.new(created)

      expect{ subject.sync_checklist(checklist) }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end

    it 'can sync records that have column values that conflict with an updated record' do
      delete_constrained_records_from_production
      Stagehand::Staging::Commit.capture do
        updated = ConstrainedRecord.create!(:unique_number => 1)
        Stagehand::Production.save(updated)
        updated.update!(:unique_number => 2)
        ConstrainedRecord.create!(:unique_number => 1)
      end

      created = ConstrainedRecord.last
      checklist = Stagehand::Staging::Checklist.new(created)
      expect{ subject.sync_checklist(checklist) }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end
  end

  shared_examples_for 'sync callbacks' do
    class SyncCallbackMock < SourceRecord
      before_sync :before_sync_callback
      after_sync :after_sync_callback
      before_sync_as_subject :before_sync_as_subject_callback
      after_sync_as_subject :after_sync_as_subject_callback
      before_sync_as_affected :before_sync_as_affected_callback
      after_sync_as_affected :after_sync_as_affected_callback

      def before_sync_callback
        self.name << '[before]'
        save!
      end

      def after_sync_callback
        self.name << '[after]'
        save!
      end

      def before_sync_as_subject_callback
        self.name << '[before_as_subject]'
        save!
      end

      def after_sync_as_subject_callback
        self.name << '[after_as_subject]'
        save!
      end

      def before_sync_as_affected_callback
        self.name << '[before_as_affected]'
        save!
      end

      def after_sync_as_affected_callback
        self.name << '[after_as_affected]'
        save!
      end
    end

    let(:record) { SyncCallbackMock.create(:name => '') }
    let(:other) { SyncCallbackMock.create(:name => '') }

    it 'runs :before_sync callback' do
      subject.sync_record(record)
      expect(record.reload.name).to include('[before]')
    end

    it 'runs :after_sync callback' do
      subject.sync_record(record)
      expect(record.reload.name).to include('[after]')
    end

    it 'does not run callbacks if the :callbacks option is false' do
      subject.sync_record(record, callbacks: false)
      expect(record.reload.name).not_to include('[after]')
    end

    it 'runs :before_sync_as_subject callback if the record is the subject of the checklist' do
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).to include('[before_as_subject]')
    end

    it 'does not run :before_sync_as_subject callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).not_to include('[before_as_subject]')
    end

    it 'runs :after_sync_as_subject callback if the record is the subject of the checklist' do
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).to include('[after_as_subject]')
    end

    it 'does not run :after_sync_as_subject callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).not_to include('[after_as_subject]')
    end

    it 'runs :before_sync_as_affected callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).to include('[before_as_affected]')
    end

    it 'does not run :before_sync_as_affected callback if the record is the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).not_to include('[before_as_affected]')
    end

    it 'runs :after_sync_as_affected callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).to include('[after_as_affected]')
    end

    it 'does not run :after_sync_as_affected callback if the record is the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).not_to include('[after_as_affected]')
    end
  end

  context 'in a multi-database configuration' do
    it_behaves_like 'sync callbacks'
  end

  in_single_connection_mode do
    it_behaves_like 'sync callbacks'
  end

  in_ghost_mode do
    it_behaves_like 'sync callbacks'
  end
end

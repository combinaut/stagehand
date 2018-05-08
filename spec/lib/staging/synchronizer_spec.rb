describe Stagehand::Staging::Synchronizer do
  let(:source_record) { SourceRecord.create }

  def delete_constrained_records_from_production
    Stagehand::Database
      .with_production_connection { ConstrainedRecord.all.to_a }
      .each {|record| Stagehand::Production.delete(record) }
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
      start_operation = Stagehand::Staging::CommitEntry.start_operations.create
      source_record.increment!(:counter)
      expect { subject.sync }.not_to change { Stagehand::Production.status(source_record) }
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
      updated.update_attributes!(:unique_number => 2)

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

    it 'does not delete active commit starts where the record is the subject when syncing an entry from a different session' do
      source_record
      Stagehand::Staging::CommitEntry.last.update_column(:session, 'some other session')
      start_operation = Stagehand::Staging::CommitEntry.start_operations.create(record_id: source_record.id, table_name: source_record.class.table_name)
      subject.sync

      expect(start_operation.class.where(id: start_operation)).to exist
    end

    it 'does not delete active commit starts where the record is the subject when an entry exists from a different session that came after' do
      source_record
      Stagehand::Staging::CommitEntry.last.delete
      start_operation = Stagehand::Staging::CommitEntry.start_operations.create(record_id: source_record.id, table_name: source_record.class.table_name)
      source_record.touch
      Stagehand::Staging::CommitEntry.last.update_column(:session, 'some other session')
      subject.sync

      expect(start_operation.class.where(id: start_operation)).to exist
    end

    it 'stops syncing once the limit has been reached' do
      record_1 = SourceRecord.create
      record_2 = SourceRecord.create

      subject.sync(1)
      statuses = [record_1, record_2].collect {|record| Stagehand::Production.status(record) }

      expect(statuses.count(:not_modified)).to eq(1)
    end

    it 'can handle many autosyncable commit entries' do
      count = 100_000
      table_name = SourceRecord.table_name
      operation = Stagehand::Staging::CommitEntry::INSERT_OPERATION
      values = count.times.collect {|index| "(#{index},'#{table_name}','#{operation}')" }.join(',')
      insert = "INSERT INTO #{Stagehand::Staging::CommitEntry.table_name} (record_id,table_name,operation) VALUES#{values};"
      ActiveRecord::Base.connection.execute(insert)

      expect { subject.sync(1000) }.to take_less_than(10).seconds
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
      updated.update_attributes!(:unique_number => 2)

      created = ConstrainedRecord.create!(:unique_number => 1)

      expect{ subject.sync_all }.to change { Stagehand::Production.status(created) }.from(:new).to(:not_modified)
    end
  end

  describe '::sync_now' do
    it 'requires a block' do
      expect { subject.sync_now }.to raise_exception(Stagehand::SyncBlockRequired)
    end

    it 'immediately syncs records modified from within the block if they are not part of an existing commit' do
      expect { subject.sync_now { source_record.increment!(:counter) } }
        .to change { Stagehand::Production.status(source_record) }.from(:new).to(:not_modified)
    end

    it 'does not sync records modified from within the block if they are part of an existing commit' do
      Stagehand::Staging::Commit.capture { source_record.increment!(:counter) }
      expect { subject.sync_now { source_record.increment!(:counter) } }.not_to change { Stagehand::Production.status(source_record) }
    end

    it 'does not sync records modified from within the block if they are the subject of an existing commit' do
      Stagehand::Staging::Commit.capture(source_record) { source_record.increment!(:counter) }
      expect { subject.sync_now { source_record.increment!(:counter) } }.not_to change { Stagehand::Production.status(source_record) }
    end

    it 'does not sync changes to records not modified in the block' do
      other_record = SourceRecord.create
      expect { subject.sync_now { source_record.increment!(:counter) } }.not_to change { Stagehand::Production.status(other_record) }
    end

    context 'when multiple connections are modifying a record during the block' do
      without_transactional_fixtures

      let(:thread_1) do
        Thread.new do
          subject.sync_now do
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

        expect(Stagehand::Production.find(source_record)).not_to have_attributes(:name => 'Bob')
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
        updated.update_attributes!(:unique_number => 2)
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
        self.name << 'before'
        save!
      end

      def after_sync_callback
        self.name << 'after'
        save!
      end

      def before_sync_as_subject_callback
        self.name << 'before_as_subject'
        save!
      end

      def after_sync_as_subject_callback
        self.name << 'after_as_subject'
        save!
      end

      def before_sync_as_affected_callback
        self.name << 'before_as_affected'
        save!
      end

      def after_sync_as_affected_callback
        self.name << 'after_as_affected'
        save!
      end
    end

    let(:record) { SyncCallbackMock.create(:name => '') }
    let(:other) { SyncCallbackMock.create(:name => '') }

    it 'runs :before_sync callback' do
      subject.sync_record(record)
      expect(record.reload.name).to include('before')
    end

    it 'runs :after_sync callback' do
      subject.sync_record(record)
      expect(record.reload.name).to include('after')
    end

    it 'runs :before_sync_as_subject callback if the record is the subject of the checklist' do
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).to include('before_as_subject')
    end

    it 'does not run :before_sync_as_subject callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).not_to include('before_as_subject')
    end

    it 'runs :after_sync_as_subject callback if the record is the subject of the checklist' do
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).to include('after_as_subject')
    end

    it 'does not run :after_sync_as_subject callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).not_to include('after_as_subject')
    end

    it 'runs :before_sync_as_affected callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).to include('before_as_affected')
    end

    it 'does not run :before_sync_as_affected callback if the record is the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).not_to include('before_as_affected')
    end

    it 'runs :after_sync_as_affected callback if the record is not the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(other.reload.name).to include('after_as_affected')
    end

    it 'does not run :after_sync_as_affected callback if the record is the subject of the checklist' do
      Stagehand::Staging::Commit.capture { record; other }
      subject.sync_checklist(Stagehand::Staging::Checklist.new(record))
      expect(record.reload.name).not_to include('after_as_affected')
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

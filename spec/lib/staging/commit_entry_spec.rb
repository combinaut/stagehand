describe Stagehand::Staging::CommitEntry do
  let(:klass) { Stagehand::Staging::CommitEntry }
  let(:source_record) { SourceRecord.create }
  subject { source_record; Stagehand::Staging::CommitEntry.last }

  describe '::create' do
    it 'sets the committed flag to false' do
      expect(klass.insert_operations.create.reload).to have_attributes(:committed => false)
    end
  end

  describe '::matching' do
    it 'returns a list of entries that match the given source_record' do
      expect(klass.matching(source_record)).to contain_exactly(subject)
    end

    it 'returns a list of entries that match the given CommitEntry' do
      other_entry = subject.dup
      other_entry.save
      expect(klass.matching(subject)).to contain_exactly(subject, other_entry)
    end

    it 'returns a list of entries that match the given array of source records' do
      expect(klass.matching([source_record])).to contain_exactly(subject)
    end

    it 'returns an empty array if given an empty array' do
      source_record
      expect(klass.matching([])).to be_empty
    end

    it 'returns an empty array if given a nil' do
      source_record
      expect(klass.matching(nil)).to be_empty
    end

    it 'returns matching control operations' do
      start_operation = klass.start_operations.create(:commit_id => 1)
      end_operation = klass.end_operations.create(:commit_id => 1)
      expect(klass.matching([start_operation, end_operation])).to include(start_operation, end_operation)
    end
  end

  describe '#valid?' do
    it 'is false if an record_id is present without a table_name' do
      expect { subject.table_name = nil }.to change { subject.valid? }.to(false)
    end

    it 'is false if an table_name is present without a record_id' do
      expect { subject.record_id = nil }.to change { subject.valid? }.to(false)
    end
  end

  describe '#record_class' do
    subject { klass.last }
    context 'on an entry referencing a table used by multiple models' do
      it 'returns the class used to create the entry if it was a descendant STI model' do
        record = STISourceRecord.create
        expect(subject.record_class).to eq(record.class)
      end

      it 'returns the class used to create the entry if it was a root STI model' do
        record = SourceRecord.create
        expect(subject.record_class).to eq(record.class)
      end

      it 'returns the class used to create the entry if it was a root STI model' do
        record = SourceRecord.create
        expect(subject.record_class).to eq(record.class)
      end

      it 'prefers the canonical class for a table over another class that shares the same table' do
        # Simulate a non-STI class that shares the same table as SourceRecord
        # (e.g. a test mock that sets `self.table_name = SourceRecord.table_name`)
        table_squatter = Class.new(ActiveRecord::Base) { self.table_name = SourceRecord.table_name }
        stub_const('TableSquatter', table_squatter)

        record = SourceRecord.create
        expect(subject.record_class).to eq(SourceRecord)
      end

      it 'raises an exception if the record class could not be determined from the table_name' do
        entry = klass.create(:record_id => 1, :table_name => 'fake_table', :operation => :insert)
        expect { subject.record_class }.to raise_exception(Stagehand::MissingTable)
      end

      it 'creates a dummy class if the record class could not be determined from the table_name but the table exists' do
        subject = klass.create(:record_id => 1, :table_name => 'habtm_records', :operation => :insert)
        expect(subject.record_class.name).to eq('Stagehand::DummyClass::HabtmRecord')
      end

      it 'falls back to returning the base class of a delete operation entry whose record has never been synced to production' do
        record = STISourceRecord.create
        record.destroy
        expect(subject.record_class).to eq(record.class.base_class)
      end

      it 'raises an exception when trying to update to an invalid sti type' do
        record = STISourceRecord.create
        Stagehand::Production.save(record)
        record.update_column(:type, "Invalid::Subtype")

        expect { subject.record_class }.to raise_exception(ActiveRecord::SubclassNotFound)
      end

      it 'creates a dummy class if the subtype is invalid for a delete operation entry whose record has been synced to production' do
        record = STISourceRecord.create
        Stagehand::Production.save(record)
        Stagehand::Production.write(record, :type => 'Invalid::Subtype')
        record.destroy

        expect(subject.record_class).to eq(Stagehand::DummyClass::SourceRecord)
      end
    end
  end

  describe '#record' do
    it 'can load records from dummy classes' do
      ActiveRecord::Base.connection.execute('INSERT INTO habtm_records VALUES ()')
      subject = Stagehand::Staging::CommitEntry.last
      expect(subject.record).to be_a(Stagehand::DummyClass::HabtmRecord)
    end

    context 'on an insert operation entry' do
      it 'returns the record represented by the row that triggered this entry' do
        expect(subject.record).to eq(source_record)
      end
    end

    context 'on a delete operation entry' do
      before do
        Stagehand::Production.save(source_record)
        source_record.reload # reload ensures timestamps are only as accurate as the database can store
        source_record.delete
      end

      it 'returns an object with the same class as the production record' do
        expect(subject.record).to be_a(source_record.class)
      end

      it 'returns an object whose attributes are populated by the production record' do
        expect(subject.record).to have_attributes(source_record.attributes)
      end

      it 'is no destroyed' do
        expect(subject.record.destroyed?).to be(false)
      end

      it 'is a Stagehand::DeletedRecord' do
        expect(subject.record).to be_a(Stagehand::DeletedRecord)
      end

      it 'raises a read_only exception when saving' do
        expect { subject.record.save }.to raise_exception(ActiveRecord::ReadOnlyRecord)
      end

      context 'when the record has a serialized data column' do
        let(:source_record) { SerializedColumnRecord.create!(tags: %w(big red truck)) }

        it 'populates serialized attributes correctly' do
          expect(subject.record).to have_attributes(source_record.attributes)
        end
      end

      context 'when the record is an STI subclass' do
        let(:source_record) { STISourceRecord.create! }

        it 'populates serialized attributes correctly' do
          expect(subject.record).to be_a(source_record.class)
        end
      end
    end
  end
end

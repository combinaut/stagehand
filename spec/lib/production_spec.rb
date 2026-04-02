describe Stagehand::Production do
  subject { Stagehand::Production }
  let(:source_record) { SourceRecord.create }

  in_single_connection_mode do
    it 'uses the same connection object as ActiveRecord::Base' do
      expect(Stagehand::Production::Record.connection).to be_equal(ActiveRecord::Base.connection)
    end
  end

  describe '::status' do
    it 'returns :new if the record does not exist in the production database' do
      expect(subject.status(source_record)).to eq(:new)
    end

    it 'returns :modified if the record exists in the production database, but its attributes are different' do
      Stagehand::Production.save(source_record)
      source_record.update_attribute(:updated_at, 10.days.from_now)
      expect(subject.status(source_record)).to eq(:modified)
    end

    it 'returns :not_modified if the record exists in the production database and its attributes are the same' do
      Stagehand::Production.save(source_record)
      expect(subject.status(source_record)).to eq(:not_modified)
    end
  end

  describe '::matching' do
    it 'returns an ActiveRecord::Relation' do
      expect(subject.matching(source_record)).to be_a(ActiveRecord::Relation)
    end

    it 'includes only production records that match the given staging record' do
      production_record_1 = subject.save(SourceRecord.create)
      production_record_2 = subject.save(source_record)
      production_record_3 = subject.save(SourceRecord.create)

      expect(subject.matching(source_record)).to contain_exactly(production_record_2)
    end

    it 'does not return records that have not been saved to the production database' do
      expect(subject.matching(source_record)).to be_empty
    end

    it 'ignores STI columns and returns Production::Records' do
      source_record.update_column(:type, STISourceRecord)
      subject.save(source_record)
      expect(subject.matching(source_record)).to all(be_a Stagehand::Production::Record)
    end
  end

  shared_examples_for 'a record' do
    describe '::save' do
      it 'returns the new record' do
        expect(subject.save(source_record)).to be_a(Stagehand::Production::Record)
      end

      it 'saves the new record to the production database' do
        expect(subject.save(source_record).class.connection).not_to eq(source_record.class.connection)
      end

      it 'persists the record' do
        expect(subject.save(source_record).reload).to be_persisted
      end

      it 'uses the same id as the source record' do
        expect(subject.save(source_record).id).to eq(source_record.id)
      end

      it 'makes an exact copy of the attributes' do
        source_record.update(:name => 'test')
        source_record.reload # reload ensures timestamps are only as accurate as the database can store
        expect(subject.save(source_record).attributes).to eq(source_record.attributes)
      end

      it 'makes an exact copy of JSON attributes' do
        source_record.update(:json => { should_not: "be stored as a JSON string" })
        source_record.reload # reload ensures timestamps are only as accurate as the database can store
        expect(subject.save(source_record).attributes).to eq(source_record.attributes)
      end

      it 'writes the new record to the same table in the production database' do
        expect(subject.save(source_record).class.table_name).to eq(source_record.class.table_name)
      end

      it 'does set timestamps' do
        source_record.update(:created_at => nil, :updated_at => nil)
        expect(subject.save(source_record)).to have_attributes(:created_at => nil, :updated_at => nil)
      end

      it 'does not change timestamps' do
        source_record.update(:created_at => 1.day.ago, :updated_at => 0.5.days.ago)
        expect(subject.save(source_record)).to have_attributes(source_record.attributes.slice(:created_at, :updated_at))
      end

      it 'does not attempt to save a record that no longer exists in the staging database' do
        source_record.destroy
        expect { subject.save(source_record) }.not_to change { Stagehand::Production::Record.count }
      end

      it 'returns a production record when saving an STI record' do
        source_record.becomes!(STISourceRecord)
        expect(subject.save(source_record)).to be_a(Stagehand::Production::Record)
      end

      it 'does not copy ignored columns' do
        allow(Stagehand::Configuration).to receive(:ignored_columns).and_return(source_record.class.table_name => 'name')
        source_record.update(:name => 'fail')
        expect(subject.save(source_record)).not_to have_attributes(:name => 'fail')
      end
    end

    describe '#write' do
      it 'returns a Stagehand::Production::Record' do
        expect(subject.write(source_record, source_record.attributes)).to be_a(Stagehand::Production::Record)
      end

      it 'writes the given data to the production record' do
        expect(subject.write(source_record, :name => 'changed')).to have_attributes(:name => 'changed')
      end

      it 'writes updated data to the production record when the record is already present in the production database' do
        skip 'we are trying to replicate a bug with prepared statements but we are unable to do so'
        subject.write(source_record, :name => 'name')
        expect(subject.write(source_record, :name => 'new_name')).to have_attributes(:name => 'new_name')
      end

      it 'retains the id of the source_record when none is given' do
        expect(subject.write(source_record, :name => 'changed')).to have_attributes(:id => source_record.id)
      end

      it 'is unaffected by ignored columns settings' do
        allow(Stagehand::Configuration).to receive(:ignored_columns).and_return(source_record.class.table_name => 'name')
        expect(subject.write(source_record, :name => 'changed')).to have_attributes(:name => 'changed')
      end
    end
  end

  context 'when the record does not yet exist in the production database' do
    it_behaves_like 'a record'
  end

  context 'when the record exists in the production database' do
    let!(:live_record) { subject.save(source_record) }
    it_behaves_like 'a record'

    describe '::save' do
      it 'can update the existing record' do
        source_record.update(:name => 'changed')
        expect { subject.save(source_record) }.to change { live_record.reload.name }.to('changed')
      end
    end

    describe '::delete' do
      it 'removes the source record from the production database when given a record' do
        subject.delete(source_record)
        expect(live_record.class.where(:id => live_record)).not_to exist
      end

      it 'removes the source record from the production database when given an id and table name' do
        subject.delete(source_record.id, source_record.class.table_name)
        expect(live_record.class.where(:id => live_record)).not_to exist
      end
    end
  end
end

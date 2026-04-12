describe Stagehand::Database do
  let(:staging) { Rails.configuration.database_configuration[Stagehand.configuration.staging_connection_name.to_s] }
  let(:production) { Rails.configuration.database_configuration[Stagehand.configuration.production_connection_name.to_s] }

  describe Stagehand::Database::StagingProbe do
    describe '.connected_to_target_database?' do
      it 'returns true when connected to staging' do
        Stagehand::Database.with_staging_connection do
          expect(described_class.connected_to_target_database?).to be true
        end
      end

      it 'returns false when connected to production' do
        Stagehand::Database.with_production_connection do
          expect(described_class.connected_to_target_database?).to be false
        end
      end
    end

    describe '.connection' do
      it 'reuses ActiveRecord::Base.connection when connected to staging' do
        Stagehand::Database.with_staging_connection do
          expect(described_class.connection).to eq(ActiveRecord::Base.connection)
        end
      end

      it 'returns its own connection when connected to production' do
        Stagehand::Database.with_production_connection do
          expect(described_class.connection).not_to eq(ActiveRecord::Base.connection)
          expect(described_class.connection.current_database).to eq(staging['database'])
        end
      end
    end
  end

  describe Stagehand::Database::ProductionProbe do
    describe '.connected_to_target_database?' do
      it 'returns true when connected to production' do
        Stagehand::Database.with_production_connection do
          expect(described_class.connected_to_target_database?).to be true
        end
      end

      it 'returns false when connected to staging' do
        Stagehand::Database.with_staging_connection do
          expect(described_class.connected_to_target_database?).to be false
        end
      end

      in_single_connection_mode do
        it 'returns true' do
          expect(described_class.connected_to_target_database?).to be true
        end
      end
    end

    describe '.connection' do
      it 'returns its own connection when connected to staging' do
        Stagehand::Database.with_staging_connection do
          expect(described_class.connection).not_to eq(ActiveRecord::Base.connection)
          expect(described_class.connection.current_database).to eq(production['database'])
        end
      end

      it 'reuses ActiveRecord::Base.connection when connected to production' do
        Stagehand::Database.with_production_connection do
          expect(described_class.connection).to eq(ActiveRecord::Base.connection)
        end
      end

      in_single_connection_mode do
        it 'reuses ActiveRecord::Base.connection' do
          expect(described_class.connection).to eq(ActiveRecord::Base.connection)
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) do

    # Create tables in the test and production database so we test copying from one to the other
    [Stagehand.configuration.staging_connection_name, Stagehand.configuration.production_connection_name].each do |connection_name|

      Stagehand::Database.with_connection(connection_name) do

        ActiveRecord::Schema.define(version: 0) do
          ActiveRecord::Base.connection.tables.each {|table_name| drop_table(table_name) }

          create_table :schema_migrations, :id => false do |t|
            t.string :version
          end

          create_table :source_records, :force => true do |t|
            t.string :name
            t.integer :counter
            t.string :type
            t.json :json # JSON column to test copying serialized data
            t.references :target_assignment
            t.references :user
            t.references :attachable, :polymorphic => true
            t.timestamps :null => true
          end

          create_table :target_assignments, :force => true do |t|
            t.references :source_record
            t.references :target
            t.integer :counter
            t.timestamps :null => false
          end

          create_table :habtm_records, :force => true do |t|
          end

          create_table :serialized_column_records, :force => true do |t|
            t.text :tags
          end

          create_table :constrained_records, :force => true do |t|
            t.integer :unique_number, index: { unique: true }
            t.references :source_record
          end
          add_foreign_key :constrained_records, :source_records
        end
      end
    end

    Stagehand::Database.with_connection(Stagehand.configuration.staging_connection_name) do
      # Add stagehand to the staging database
      Stagehand::Schema.init_stagehand!

      # Add a table to the staging side that doesn't appear on the production side and doesn't have stagehand
      ActiveRecord::Schema.define do
        create_table :users, :force => true, :stagehand => false do |t|
          t.timestamps :null => false
        end
      end
    end
  end
end

module TransactionRetry
  extend ActiveSupport::Concern

  class_methods do
    def transaction(*args, &block)
      return super unless transaction_retry_enabled?

      attempts = 0

      super(*args) do
        yield
      rescue => e
        attempts += 1

        if attempts < 3
          retry
        else
          raise e
        end
      end
    end

    def transaction_retry_enabled?
      !!@transaction_retry_enabled
    end

    def transaction_retry_enabled=(bool)
      @transaction_retry_enabled = bool
    end

    def with_transaction_retry_enabled(&block)
      previous_value = transaction_retry_enabled?

      self.transaction_retry_enabled = true
      yield
    ensure
      self.transaction_retry_enabled = previous_value
    end
  end
end
ActiveRecord::Base.send(:include, TransactionRetry)

# Create the model
class SourceRecord < ActiveRecord::Base
  belongs_to :user
  belongs_to :attachable, :polymorphic => true

  # Scoped instance-dependent association to test fix for https://github.com/combinaut/stagehand/issues/52
  belongs_to :target_assignment, ->(record) { where source_record: record }

  has_many :target_assignments
  has_many :targets, through: :target_assignments
end

class STISourceRecord < SourceRecord; end

class TargetAssignment < ActiveRecord::Base
  belongs_to :source_record
  belongs_to :target, class_name: 'SourceRecord'
end

class SerializedColumnRecord < ActiveRecord::Base
  serialize :name
end

class ConstrainedRecord < ActiveRecord::Base;
  belongs_to :source_record
end

class User < ActiveRecord::Base; end

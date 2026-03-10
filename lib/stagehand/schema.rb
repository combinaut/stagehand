require "stagehand/schema/statements"

module Stagehand
  module Schema
    extend self

    UNTRACKED_TABLES = ['ar_internal_metadata', 'schema_migrations', 'data_migrations', Stagehand::Staging::CommitEntry.table_name]

    def init_stagehand!(**table_options)
      ActiveRecord::Schema.define do
        create_table :stagehand_commit_entries do |t|
          t.integer :record_id
          t.string :table_name
          t.string :operation, :null => false
          t.integer :commit_id
          t.boolean :committed, :null => false, :default => false
          t.datetime :created_at
        end

        add_index :stagehand_commit_entries, :commit_id # Used for looking up all entries within a commit
        add_index :stagehand_commit_entries, [:record_id, :table_name, :committed], :name => 'index_stagehand_commit_entries_for_matching' # Used for 'matching' scope
        add_index :stagehand_commit_entries, [:operation, :committed, :commit_id], :name => 'index_stagehand_commit_entries_for_loading' # Used for looking up start entries
      end

      Stagehand::Staging::CommitEntry.reset_column_information

      add_stagehand!(table_options)
    end


    def add_stagehand!(force: false, **table_options)
      return if Database.connected_to_production? && !Stagehand::Configuration.single_connection?

      ActiveRecord::Schema.define do
        Stagehand::Schema.send :each_table, **table_options do |table_name|
          Stagehand::Schema.send :create_operation_trigger, table_name, 'insert', 'NEW', force: force
          Stagehand::Schema.send :create_operation_trigger, table_name, 'update', 'NEW', force: force
          Stagehand::Schema.send :create_operation_trigger, table_name, 'delete', 'OLD', force: force
        end
      end
    end

    def remove_stagehand!(remove_entries: true, **table_options)
      ActiveRecord::Schema.define do
        Stagehand::Schema.send :each_table, **table_options do |table_name|
          next unless Stagehand::Schema.send :has_stagehand_triggers?, table_name
          Stagehand::Schema.send :drop_trigger, table_name, 'insert'
          Stagehand::Schema.send :drop_trigger, table_name, 'update'
          Stagehand::Schema.send :drop_trigger, table_name, 'delete'
          Stagehand::Schema.send :expunge, table_name if remove_entries
        end

        drop_table :stagehand_commit_entries unless table_options[:only].present?
      end
    end

    def has_stagehand?(table_name = nil)
      if UNTRACKED_TABLES.include?(table_name.to_s)
        return false
      elsif table_name
        has_stagehand_triggers?(table_name)
      else
        ActiveRecord::Base.connection.table_exists?(Stagehand::Staging::CommitEntry.table_name)
      end
    end

    private

    def each_table(only: nil, except: nil)
      table_names = ActiveRecord::Base.connection.tables
      table_names -= UNTRACKED_TABLES
      table_names -= Array(except).collect(&:to_s)
      table_names &= Array(only).collect(&:to_s) if only.present?

      table_names.each do |table_name|
        yield table_name
      end
    end

    def create_operation_trigger(table_name, trigger_event, record, force: false)
      if force
        drop_trigger(table_name, trigger_event)
      elsif trigger_exists?(table_name, trigger_event)
        return
      end

      create_trigger(table_name, trigger_event, :after, <<-SQL)
        BEGIN
          INSERT INTO stagehand_commit_entries (record_id, table_name, operation, commit_id, created_at)
          VALUES (#{record}.id, '#{table_name}', '#{trigger_event}', @stagehand_commit_id, CURRENT_TIMESTAMP());
        END;
      SQL
    end

    def create_trigger(table_name, trigger_event, trigger_time, row_action)
      ActiveRecord::Base.connection.execute <<-SQL
        CREATE TRIGGER #{trigger_name(table_name, trigger_event)} #{trigger_time} #{trigger_event}
        ON #{table_name} FOR EACH ROW #{row_action}
      SQL
    end

    def drop_trigger(table_name, trigger_event)
      ActiveRecord::Base.connection.execute("DROP TRIGGER IF EXISTS #{trigger_name(table_name, trigger_event)};")
    end

    def trigger_exists?(table_name, trigger_event)
      ActiveRecord::Base.connection.select_one("SHOW TRIGGERS where `trigger` = '#{trigger_name(table_name, trigger_event)}'").present?
    end

    def has_stagehand_triggers?(table_name)
      get_triggers(table_name).present?
    end

    def trigger_name(table_name, trigger_event)
      "stagehand_#{trigger_event}_trigger_#{table_name}".downcase
    end

    def get_triggers(table_name = nil)
      statement = <<~SQL
        SHOW TRIGGERS WHERE `Trigger` LIKE 'stagehand_%'
      SQL
      statement << " AND `Table` LIKE #{ActiveRecord::Base.connection.quote(table_name)}" if table_name.present?

      return ActiveRecord::Base.connection.select_all(statement)
    end

    def expunge(table_name)
      commit_ids = [] # Keep track of commits that we need to clean up if they're now empty

      # Remove records from the table as the subject of any commits
      Stagehand::Staging::CommitEntry.start_operations.where(:table_name => table_name).in_batches do |batch|
        commit_ids.concat batch.contained.distinct.pluck(:commit_id)
        batch.update_all(:record_id => nil, :table_name => nil)
      end

      # Remove commit entries for records from the table
      Stagehand::Staging::CommitEntry.content_operations.where(:table_name => table_name).in_batches do |batch|
        commit_ids.concat batch.contained.distinct.pluck(:commit_id)
        batch.delete_all
      end

      Stagehand::Staging::Commit.find(commit_ids).select(&:empty?).each(&:destroy)
    end
  end
end

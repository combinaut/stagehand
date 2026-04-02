module Stagehand
  module RailsCompatibility
    def self.adapter_database_name_for(connection)
      if connection.respond_to?(:connection_db_config)
        connection.connection_db_config.database
      elsif connection.respond_to?(:db_config)
        connection.db_config.database
      else
        connection.instance_variable_get(:@config)[:database]
      end
    end

    def self.schema_migration_table_name_for(connection)
      if ActiveRecord::SchemaMigration.respond_to?(:table_name)
        ActiveRecord::SchemaMigration.table_name
      elsif connection.respond_to?(:schema_migration) && connection.schema_migration.respond_to?(:table_name)
        connection.schema_migration.table_name
      else
        'schema_migrations'
      end
    end
  end
end

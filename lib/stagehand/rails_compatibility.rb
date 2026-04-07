module Stagehand
  # Small compatibility shims for Rails/ActiveRecord API differences across
  # the appraisal matrix.
  module RailsCompatibility
    # Resolve the current database name from an adapter instance across Rails
    # versions where configuration accessors changed.
    def self.adapter_database_name_for(connection)
      if connection.respond_to?(:connection_db_config)
        connection.connection_db_config.database
      elsif connection.respond_to?(:db_config)
        connection.db_config.database
      else
        connection.instance_variable_get(:@config)[:database]
      end
    end

    # Resolve schema migration table name across Rails versions where
    # `ActiveRecord::SchemaMigration` and connection APIs differ.
    def self.schema_migration_table_name_for(connection)
      if ActiveRecord::SchemaMigration.respond_to?(:table_name)
        ActiveRecord::SchemaMigration.table_name
      elsif connection.respond_to?(:schema_migration) && connection.schema_migration.respond_to?(:table_name)
        connection.schema_migration.table_name
      else
        'schema_migrations'
      end
    end

    # Select adapter classes to patch for Stagehand extension modules.
    # Concrete adapters are preferred so prepended overrides win method lookup
    # over adapter-specific modules; fall back to `AbstractAdapter` when no
    # known concrete adapter is available.
    def self.supported_adapter_classes_for_extensions
      adapter_classes = []
      adapter_classes << ActiveRecord::ConnectionAdapters::Mysql2Adapter if defined?(ActiveRecord::ConnectionAdapters::Mysql2Adapter)
      adapter_classes << ActiveRecord::ConnectionAdapters::TrilogyAdapter if defined?(ActiveRecord::ConnectionAdapters::TrilogyAdapter)
      adapter_classes << ActiveRecord::ConnectionAdapters::AbstractAdapter if adapter_classes.empty?
      adapter_classes
    end
  end
end

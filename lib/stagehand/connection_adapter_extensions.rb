require 'stagehand/rails_compatibility'
require 'stagehand/adapter_extender'

module Stagehand
  module Connection
    def self.with_production_writes(&block)
      state = allow_unsynced_production_writes?
      allow_unsynced_production_writes!(true)
      return block.call
    ensure
      allow_unsynced_production_writes!(state)
    end

    def self.allow_unsynced_production_writes!(state = true)
      Thread.current.thread_variable_set(:stagehand_allow_unsynced_production_writes, state)
    end

    def self.allow_unsynced_production_writes?
      !!Thread.current.thread_variable_get(:stagehand_allow_unsynced_production_writes)
    end

    module AdapterExtensions
      def quote_table_name(table_name)
        if prefix_table_name_with_database?(table_name)
          super("#{Stagehand::Database.staging_database_name}.#{table_name}")
        else
          super
        end
      end

      def prefix_table_name_with_database?(table_name)
        return false if Configuration.single_connection?
        return false if Connection.allow_unsynced_production_writes?
        return false unless Configuration.staging_model_tables.include?(table_name)

        # Prefix when we're on a production connection (per Stagehand stack) or
        # when the adapter itself is pointed at production. If both the stack
        # and adapter say staging, no prefix is needed.
        adapter_db = Stagehand::RailsCompatibility.adapter_database_name_for(self)

        return false if adapter_db == Database.staging_database_name && !Database.connected_to_production?

        true
      end

      def exec_insert(sql, *, **)
        handle_readonly_writes!(sql.respond_to?(:to_sql) ? sql.to_sql : sql)
        super
      end

      def exec_update(sql, *, **)
        handle_readonly_writes!(sql.respond_to?(:to_sql) ? sql.to_sql : sql)
        super
      end

      def exec_delete(sql, *, **)
        handle_readonly_writes!(sql.respond_to?(:to_sql) ? sql.to_sql : sql)
        super
      end

      private

      def write_access?
        Configuration.single_connection? || adapter_database_name == Database.staging_database_name || Connection.allow_unsynced_production_writes?
      end

      def handle_readonly_writes!(sql)
        database_name = adapter_database_name

        if write_access?
          return
        elsif Configuration.allow_unsynced_production_writes?
          Rails.logger.warn "Writing directly to #{database_name} database using readonly connection"
        else
          raise(UnsyncedProductionWrite, "Attempted to write directly to #{database_name} database using readonly connection: #{sql}")
        end
      end

      def adapter_database_name
        Stagehand::RailsCompatibility.adapter_database_name_for(self)
      end
    end
  end


  # EXCEPTIONS

  class UnsyncedProductionWrite < StandardError; end
end

Stagehand::AdapterExtender.prepend_on_active_record_load(Stagehand::Connection::AdapterExtensions)

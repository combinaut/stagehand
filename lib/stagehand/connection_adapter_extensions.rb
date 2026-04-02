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
        return false unless Database.connected_to_production?
        return false if Connection.allow_unsynced_production_writes?
        return false unless Configuration.staging_model_tables.include?(table_name)
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
        Configuration.single_connection? || @config[:database] == Database.staging_database_name || Connection.allow_unsynced_production_writes?
      end

      def handle_readonly_writes!(sql)
        if write_access?
          return
        elsif Configuration.allow_unsynced_production_writes?
          Rails.logger.warn "Writing directly to #{@config[:database]} database using readonly connection"
        else
          raise(UnsyncedProductionWrite, "Attempted to write directly to #{@config[:database]} database using readonly connection: #{sql}")
        end
      end
    end
  end


  # EXCEPTIONS

  class UnsyncedProductionWrite < StandardError; end
end

ActiveRecord::Base.connection.class.prepend(Stagehand::Connection::AdapterExtensions)

require 'stagehand/rails_compatibility'
require 'stagehand/active_record_extensions'

module Stagehand
  module Database
    extend self

    STAGING_SHARD = :staging
    PRODUCTION_SHARD = :production
    private_constant :STAGING_SHARD, :PRODUCTION_SHARD

    # Register shard connections on ActiveRecord::Base. Called from engine initializer.
    def configure_shards!

      ActiveRecord::Base.connects_to shards: {
        STAGING_SHARD    => { writing: Configuration.staging_connection_name },
        PRODUCTION_SHARD => { writing: Configuration.production_connection_name }
      }

      # StagingProbe needs pools in both shards so Staging::Model classes can
      # resolve a connection when the production shard is active.
      StagingProbe.connects_to shards: {
        STAGING_SHARD    => { writing: Configuration.staging_connection_name },
        PRODUCTION_SHARD => { writing: Configuration.staging_connection_name }
      }

      # ProductionProbe needs pools in both shards so Production::Record
      # can resolve a connection regardless of the active shard.
      # In single-connection mode, skip this so ProductionProbe inherits
      # ActiveRecord::Base's pool — ensuring connection and connection_pool
      # resolve identically (e.g. for ActiveRecord finders inside transactions).
      # In single-connection mode, skip this so ProductionProbe inherits
      # ActiveRecord::Base's pool — ensuring connection and connection_pool
      # resolve identically (e.g. for ActiveRecord finders inside transactions).
      unless Configuration.single_connection?
        ProductionProbe.connects_to shards: {
          STAGING_SHARD    => { writing: Configuration.production_connection_name },
          PRODUCTION_SHARD => { writing: Configuration.production_connection_name }
        }
      end
    end

    def transaction
      raise InvalidConnectionError, "Calling Stagehand::Database.transaction is not valid unless connected to staging" unless connected_to_staging?

      success = false
      attempts = 0
      output = nil
      ActiveRecord::Base.transaction do
        callable = proc do
          attempts += 1

          raise NoRetryError, "Retrying is not allowed in Stagehand::Database.transaction" if attempts > 1

          output = yield

          success = true
        end

        # In single connection mode, skip Production::Record transaction to avoid
        # connection issues (ProductionProbe has no dedicated pool).
        if Configuration.single_connection?
          callable.call
        else
          Production::Record.transaction(&callable)
        end

        raise ActiveRecord::Rollback unless success
      end

      return output
    ensure
      Rails.logger.warn "Stagehand::Database transaction was rolled back" unless success
    end

    def each(&block)
      with_production_connection(&block) unless Configuration.single_connection?
      with_staging_connection(&block)
    end

    def connected_to_production?
      current_connection_name == Configuration.production_connection_name
    end

    def connected_to_staging?
      current_connection_name == Configuration.staging_connection_name
    end

    def production_connection
      ProductionProbe.connection
    end

    def staging_connection
      StagingProbe.connection
    end

    def production_database_name
      database_name(Configuration.production_connection_name)
    end

    def staging_database_name
      database_name(Configuration.staging_connection_name)
    end

    def production_database_versions
      if Configuration.single_connection?
        staging_database_versions
      else
        with_production_connection do
          schema_versions_for_connection
        end
      end
    end

    def staging_database_versions
      with_staging_connection do
        schema_versions_for_connection
      end
    end

    def with_staging_connection(&block)
      with_connection(Configuration.staging_connection_name, &block)
    end

    def with_production_connection(&block)
      with_connection(Configuration.production_connection_name, &block)
    end

    def with_connection(connection_name, &block)
      if current_connection_name != connection_name.to_sym
        Rails.logger.debug "Connecting to #{connection_name}"
        output = swap_connection(connection_name, &block)
        Rails.logger.debug "Restoring connection to #{current_connection_name}"
      else
        Rails.logger.debug "Already connected to #{connection_name}"
        output = yield connection_name
      end
      return output
    end

    private

    def swap_connection(connection_name)
      pushed = ConnectionStack.push(connection_name.to_sym)
      ActiveRecord::Base.connected_to(shard: shard_for_connection(connection_name), role: :writing) do
        yield connection_name
      end
    ensure
      ConnectionStack.pop if pushed
    end

    def shard_for_connection(connection_name)
      case connection_name.to_sym
      when Configuration.staging_connection_name.to_sym
        STAGING_SHARD
      when Configuration.production_connection_name.to_sym
        PRODUCTION_SHARD
      else
        raise ArgumentError, "Unknown connection name: #{connection_name}"
      end
    end

    def current_connection_name
      ConnectionStack.last
    end

    def database_name(connection_name)
      database_configuration.dig(connection_name.to_s, 'database')
    end

    def database_configuration
      @database_configuration ||= Rails.configuration.database_configuration
    end

    def schema_versions_for_connection
      connection = ActiveRecord::Base.connection
      table_name = Stagehand::RailsCompatibility.schema_migration_table_name_for(connection)
      table = connection.quote_table_name(table_name)
      connection.select_values("SELECT version FROM #{table} ORDER BY version ASC").map(&:to_s)
    rescue ActiveRecord::StatementInvalid
      []
    end

    # CLASSES

    class Probe < ActiveRecord::Base
      self.abstract_class = true

      # Reuse ActiveRecord::Base.connection when the current shard targets the
      # same database as this probe, so we stay within the current transaction.
      def self.connection
        if connected_to_target_database?
          ActiveRecord::Base.connection
        else
          super
        end
      end

      def self.connected_to_target_database?
        false
      end
    end

    class StagingProbe < Probe
      self.abstract_class = true

      def self.init_connection
        establish_connection(Configuration.staging_connection_name)
      end

      def self.connected_to_target_database?
        Stagehand::Database.connected_to_staging?
      end

      init_connection
    end

    class ProductionProbe < Probe
      self.abstract_class = true

      def self.init_connection
        establish_connection(Configuration.production_connection_name)
      end

      def self.connected_to_target_database?
        # In multi-connection mode, ProductionProbe has its own dedicated
        # pool (via init_connection) and should always use it — return false
        # even when connected to production so that `super` resolves through
        # the dedicated pool.
        Configuration.single_connection? && Stagehand::Database.connected_to_production?
      end

      init_connection unless Configuration.single_connection?
    end

    # Threadsafe tracking of the connection stack
    module ConnectionStack
      def self.push(connection_name)
        current_stack.push connection_name
      end

      def self.pop
        current_stack.pop
      end

      def self.last
        current_stack.last
      end

      def self.current_stack
        if stack = Thread.current.thread_variable_get('sparkle_connection_name_stack')
          stack
        else
          stack = Concurrent::Array.new
          stack << Rails.env.to_sym
          Thread.current.thread_variable_set('sparkle_connection_name_stack', stack)
          stack
        end
      end
    end

    class InvalidConnectionError < StandardError; end
    class NoRetryError < StandardError; end
  end
end

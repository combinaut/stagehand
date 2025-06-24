require 'thread'

ActiveRecord::Base.class_eval do
  # SYNC CALLBACKS
  ([self] + ActiveSupport::DescendantsTracker.descendants(self)).each do |klass|
    klass.define_model_callbacks :sync, :sync_as_subject, :sync_as_affected
  end

  # SYNC STATUS
  def self.inherited(subclass)
    super

    subclass.class_eval do
      has_one :stagehand_unsynced_indicator,
        lambda { where(:stagehand_commit_entries => {:table_name => subclass.table_name}).readonly },
        :class_name => 'Stagehand::Staging::CommitEntry',
        :foreign_key => :record_id

      has_one :stagehand_unsynced_commit_indicator,
        lambda { where(:stagehand_commit_entries => {:table_name => subclass.table_name}).where.not(commit_id: nil).readonly },
        :class_name => 'Stagehand::Staging::CommitEntry',
        :foreign_key => :record_id

      def synced?
        stagehand_unsynced_indicator.blank?
      end

      def synced_all_commits?
        stagehand_unsynced_commit_indicator.blank?
      end
    end
  end

  # SCHEMA
  delegate :has_stagehand?, to: :class
  def self.has_stagehand?
    @has_stagehand = Stagehand::Schema.has_stagehand?(table_name) unless defined?(@has_stagehand)
    return @has_stagehand
  end

  # MULTITHREADED CONNECTION HANDLING

  class_attribute :stagehand_threadsafe_connections
  self.stagehand_threadsafe_connections = true

  # The original implementation of remove_connection uses @connection_specification_name, which is shared across Threads.
  # We need to pass in the connection that model in the current thread is using if we call remove_connection.
  def self.remove_connection(name = StagehandConnectionMap.get(self))
    return super unless stagehand_threadsafe_connections

    StagehandConnectionMap.set(self, nil)
    super
  end

  def self.connection_specification_name=(connection_name)
    return super unless stagehand_threadsafe_connections

    # ActiveRecord sets the connection pool to 'primary' by default, so we want to reuse that connection for staging
    # in order to avoid using a different connection pool after our first swap back to the staging connection.
    connection_name == 'primary' if connection_name == Stagehand::Configuration.staging_connection_name

    StagehandConnectionMap.set(self, connection_name)
  end

  def self.connection_specification_name
    return super unless stagehand_threadsafe_connections

    StagehandConnectionMap.get(self) || super
  end

  # Keep track of the current connection name per-model, per-thread so multithreaded webservers don't overwrite it
  module StagehandConnectionMap
    def self.set(klass, connection_name)
      current_map[klass.name] = connection_name
    end

    def self.get(klass)
      current_map[klass.name]
    end

    def self.current_map
      map = Thread.current.thread_variable_get('StagehandConnectionMap')
      map = Thread.current.thread_variable_set('StagehandConnectionMap', Concurrent::Hash.new) unless map
      return map
    end
  end
end

module StagehandAssociationReflection
  # SOURCE: https://github.com/rails/rails/blob/a4581b53aae93a8dd3205abae0630398cbce9204/activerecord/lib/active_record/reflection.rb#L429
  def initialize(*)
    super
    @association_scope_cache = StagehandAssociationScopeCache.new
  end

  # Ensure the association query statements are cached separately for the staging and production connections or else
  # queries for Staging Models may cache the database name for the wrong connection.
  class StagehandAssociationScopeCache < Delegator
    def initialize
      @staging_cache = Concurrent::Map.new
      @production_cache = Concurrent::Map.new
    end

    def __getobj__
      Stagehand::Database.connected_to_production? ? @production_cache : @staging_cache
    end
  end
end

ActiveRecord::Reflection::AssociationReflection.prepend(StagehandAssociationReflection)

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
end

module StagehandAssociationReflection
  # SOURCE: https://github.com/rails/rails/blob/a4581b53aae93a8dd3205abae0630398cbce9204/activerecord/lib/active_record/reflection.rb#L429
  def initialize(*, **)
    super
    @association_scope_cache = StagehandAssociationScopeCache.new
  end

  # Rails 8 caches association statements via AssociationReflection#association_scope_cache
  # using cached_find_by_statement. Include Stagehand connection context in the cache key
  # so scopes built in staging are not reused in production.
  def association_scope_cache(klass, owner, &block)
    key = self
    key = [key, owner._read_attribute(@foreign_type)] if polymorphic?

    klass.with_connection do |connection|
      adapter_db = if connection.respond_to?(:connection_db_config)
        connection.connection_db_config.database
      else
        connection.current_database
      end

      context_key = [key, adapter_db, Stagehand::Database.connected_to_production?]
      klass.cached_find_by_statement(connection, context_key, &block)
    end
  end

  # Ensure the association query statements are cached separately for the staging and production connections or else
  # queries for Staging Models may cache the database name for the wrong connection.
  class StagehandAssociationScopeCache < Delegator
    def initialize
      @staging_cache = Concurrent::Map.new
      @production_cache = Concurrent::Map.new
    end

    def __getobj__
      adapter_db = if ActiveRecord::Base.connection.respond_to?(:connection_db_config)
        ActiveRecord::Base.connection.connection_db_config.database
      else
        ActiveRecord::Base.connection.current_database
      end

      adapter_db == Stagehand::Database.production_database_name ? @production_cache : @staging_cache
    end
  end
end

ActiveRecord::Reflection::AssociationReflection.prepend(StagehandAssociationReflection)

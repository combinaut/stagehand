require 'stagehand/rails_compatibility'

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
  # Rails 6.1+ caches association statements via AssociationReflection#association_scope_cache.
  # Include Stagehand connection context in the key so scopes built in staging
  # are not reused in production.
  def association_scope_cache(klass, owner, &block)
    key = self
    key = [key, owner._read_attribute(@foreign_type)] if polymorphic?

    if klass.method(:cached_find_by_statement).arity >= 2
      klass.with_connection do |connection|
        context_key = [key, stagehand_adapter_database(connection), Stagehand::Database.connected_to_production?]
        klass.cached_find_by_statement(connection, context_key, &block)
      end
    else
      context_key = [key, stagehand_adapter_database(klass.connection), Stagehand::Database.connected_to_production?]
      klass.cached_find_by_statement(context_key, &block)
    end
  end

  private

  def stagehand_adapter_database(connection)
    Stagehand::RailsCompatibility.adapter_database_name_for(connection)
  end
end

ActiveRecord::Reflection::AssociationReflection.prepend(StagehandAssociationReflection)

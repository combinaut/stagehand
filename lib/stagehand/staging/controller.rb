module Stagehand
  module Staging
    module Controller
      extend ActiveSupport::Concern
      include Stagehand::ControllerExtensions

      included do
        use_staging_database
      end

      # Creates a stagehand commit to log database changes associated with the given record
      def stage_changes(*args, **kwargs, &block)
        Staging::Commit.capture(*args, **kwargs, &block)
      end

      # Syncs the given record and all affected records to the production database
      def sync_record(record)
        Stagehand::Staging::Synchronizer.sync_record(record)
      end

      # Syncs the checklist's affected records to the production database
      def sync_checklist(checklist)
        Stagehand::Staging::Synchronizer.sync_checklist(checklist)
      end
    end
  end
end

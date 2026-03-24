module Stagehand
  module Staging
    module Model
      extend ActiveSupport::Concern

      included do
        Stagehand::Configuration.staging_model_tables << table_name if table_name 
      end

      class_methods do
        def inherited(subclass)
          super
          return if subclass.table_name.nil?

          Stagehand::Configuration.staging_model_tables << subclass.table_name
        end

        def quoted_table_name
          if connection.prefix_table_name_with_database?(table_name)
            @prefixed_quoted_table_name ||= connection.quote_table_name(table_name)
          else
            super
          end
        end

        def connection
          if Configuration.ghost_mode?
            super
          else
            Stagehand::Database::StagingProbe.connection
          end
        end
      end
    end
  end
end

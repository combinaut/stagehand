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

        def connection_pool
          if Configuration.ghost_mode? || Configuration.single_connection?
            super
          else
            ActiveRecord::Base.connected_to(shard: :staging, role: :writing) do
              ActiveRecord::Base.connection_pool
            end
          end
        end

        # Rails 8.1 soft-deprecated connection in favor of connection_pool,
        # but the adapter instance returned by connection is still used for
        # SQL execution. Without this override, writes from association proxies
        # (e.g. has_many#delete_all) go through the production shard's adapter,
        # triggering UnsyncedProductionWrite.
        def connection
          if Configuration.ghost_mode? || Configuration.single_connection?
            super
          else
            ActiveRecord::Base.connected_to(shard: :staging, role: :writing) do
              ActiveRecord::Base.connection
            end
          end
        end
      end
    end
  end
end

module Stagehand
  module AdapterDatabase
    module_function

    def name_for(connection)
      if connection.respond_to?(:connection_db_config)
        connection.connection_db_config.database
      elsif connection.respond_to?(:db_config)
        connection.db_config.database
      else
        connection.instance_variable_get(:@config)[:database]
      end
    end
  end
end
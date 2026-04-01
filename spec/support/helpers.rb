def allow_unsynced_production_writes
  use_configuration :allow_unsynced_production_writes => true
end

def in_ghost_mode(&block)
  context 'in ghost mode' do
    use_configuration(:ghost_mode => true)
    instance_exec(&block)
  end
end

def in_single_connection_mode(&block)
  context 'in a single database configuration' do
    connection = Stagehand.configuration.staging_connection_name
    use_configuration(:staging_connection_name => connection, :production_connection_name => connection)
    instance_exec(&block)
  end
end

def use_configuration(new_configuration)
  around do |example|
    with_configuration(new_configuration) do
      example.run
    end
  end
end

def with_configuration(new_configuration, &block)
  old_configuration = set_configuration(new_configuration)
  block.call rescue nil
  set_configuration(old_configuration)
end

def set_configuration(new_configuration)
  {}.tap do |old_configuration|
    new_configuration.each do |option, value|
      old_configuration[option] = Rails.configuration.x.stagehand.send("#{option}")
      Rails.configuration.x.stagehand.send("#{option}=", value)
    end

    if Stagehand::Configuration.single_connection?
      Stagehand::Database::ProductionProbe.remove_connection
    else
      Stagehand::Database::ProductionProbe.init_connection
    end
    Stagehand::Database::StagingProbe.init_connection
  end
end

def without_transactional_fixtures
  # Transactions hide changes from other connections. Disable transactional fixtures so it's easier to detect changes
  # across connections. In practice, this won't be an issue because connections will be modified at the beginning of
  # the controller action.
  #
  # This is now just a no-op to indicate which tests would require this since we no longer use transactional fixtures
end

def use_then_clear_connection_for_class(klass, connection_name)
  around do |example|
    set_then_clear_connection_for_class(klass, connection_name) do
      example.run
    end
  end
end

def set_then_clear_connection_for_class(klass, connection_name, &block)
  klass.abstract_class = true
  klass.connects_to shards: {
    staging:    { writing: connection_name },
    production: { writing: connection_name }
  }
  klass.abstract_class = false
  ActiveRecord::Base.connected_to(shard: :staging, role: :writing) do
    block.call
  end
ensure
  klass.remove_connection
  # Ensure the class falls back to ActiveRecord::Base's pool after cleanup.
  klass.connection_specification_name = ActiveRecord::Base.connection_specification_name
end

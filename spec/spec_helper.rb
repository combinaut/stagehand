ENV['RAILS_ENV'] ||= 'test'

require_relative 'internal/config/environment'

# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?

require 'rspec/rails'

# Only needed for tests
require 'database_cleaner/active_record'

# Add additional requires below this line. Rails is not loaded until this point!

ENGINE_RAILS_ROOT = File.join(File.dirname(__FILE__), '../')
Dir[File.join(ENGINE_RAILS_ROOT, "spec/support/**/*.rb")].each {|f| require f }

RSpec.configure do |config|
  config.append_after(:each) do
    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.clean
    # Teardown must be context-independent: even though staging is the default,
    # we don't rely on that default (or on examples restoring connection state)
    # before cleanup runs.
    # Delete any entries that were created due to database cleaning.
    Stagehand::Database.with_staging_connection { Stagehand::Staging::CommitEntry.delete_all }

    Stagehand::Configuration.staging_model_tables = Set.new
  end
end

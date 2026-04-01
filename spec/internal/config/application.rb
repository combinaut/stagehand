require_relative 'boot'
require 'logger'
require 'rails/all'

Bundler.require(*Rails.groups)
require 'stagehand'

module Internal
  class Application < Rails::Application
    config.root = File.expand_path('../..', __FILE__)
    config.eager_load = false
    config.x.stagehand.production_connection_name = :production

    # Suppress default Rails logging noise in test
    config.log_level = :warn
  end
end

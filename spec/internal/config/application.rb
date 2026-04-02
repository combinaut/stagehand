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
    if ActiveRecord.gem_version < Gem::Version.new('7.1') && config.active_record.respond_to?(:legacy_connection_handling=)
      config.active_record.legacy_connection_handling = false
    end

    # Suppress default Rails logging noise in test
    config.log_level = :warn
  end
end

require 'stagehand/rails_compatibility'

module Stagehand
  module AdapterExtender
    extend self

    def prepend_on_active_record_load(extension_module)
      ActiveSupport.on_load(:active_record) do
        Stagehand::AdapterExtender.prepend_to_supported_adapters(extension_module)
      end
    end

    def prepend_to_supported_adapters(extension_module)
      RailsCompatibility.supported_adapter_classes_for_extensions.each do |adapter_class|
        next if adapter_class < extension_module

        adapter_class.prepend(extension_module)
      end
    end
  end
end

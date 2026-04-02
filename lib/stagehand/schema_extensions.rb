module Stagehand
  module SchemaExtensions
    def define(*, **)
      # Allow production writes during Schema.define to allow Rails to write to ar_internal_metadata table
      Stagehand::Connection.with_production_writes { super }
    end
  end
end

ActiveRecord::Schema.prepend(Stagehand::SchemaExtensions)

module Stagehand
  module Key
    extend self

    def generate(staging_record, options = {})
      Stagehand::Staging::Synchronizer::Profiler.measure(:Key_generate) do
        case staging_record
        when Staging::CommitEntry
          id = staging_record.record_id || staging_record.id
          table_name = staging_record.table_name || staging_record.class.table_name
        when ActiveRecord::Base
          id = staging_record.id
          table_name = staging_record.class.table_name
        else
          id = staging_record
          table_name = options[:table_name]
        end

        raise 'Invalid input' unless table_name && id

        [table_name, id]
      end
    end
  end
end

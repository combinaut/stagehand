require 'rake'

module Stagehand
  module RakeHelpers
    extend self
    extend Rake::DSL

    def rake_both_databases(task_name, stagehand_task = task_name.gsub(':','_'))
      original_task = Rake::Task[task_name]
      original_actions = original_task.actions.dup

      task(stagehand_task => :environment) do
        Stagehand::Database.each do |connection_name|
          Stagehand::Connection.with_production_writes do
            if task_name == 'db:create'
              # db:create resolves configurations from environment names; explicitly
              # create the target connection's database so production isn't skipped.
              ActiveRecord::Tasks::DatabaseTasks.create(connection_name)
            else
              # Some Rails versions evaluate migration tasks against ActiveRecord::Base's
              # primary pool regardless of connected_to context.
              ActiveRecord::Base.establish_connection(connection_name)
              # Execute the original task actions directly to avoid re-triggering
              # prerequisites while we fan out across both connections.
              original_actions.each do |action|
                action.call(original_task, Rake::TaskArguments.new(original_task.arg_names, []))
              end
            end
          end
        end
        Rake::Task[task_name].clear_actions
      end

      Rake::Task[task_name].enhance(["stagehand:#{stagehand_task}"])
    end
  end
end

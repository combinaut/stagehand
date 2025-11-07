namespace :stagehand do
  desc "Polls the commit entries table for changes to sync to production"
  task :auto_sync, [:delay] => :environment do |t, args|
    delay = args[:delay].present? ? args[:delay].to_i : 5.seconds
    Stagehand::Staging::Synchronizer.auto_sync(delay)
  end

  desc "Syncs records that don't need confirmation to production"
  task :sync, [:limit] => :environment do |t, args|
    limit = args[:limit].present? ? args[:limit].to_i : nil
    Stagehand::Staging::Synchronizer.sync(limit)
  end

  desc "Syncs all records to production, including those that require confirmation"
  task :sync_all => :environment do
    Stagehand::Staging::Synchronizer.sync_all
  end

  # Enhance the regular tasks to run on both staging and production databases
  def rake_both_databases(task, stagehand_task = task.gsub(':','_'))
    task(stagehand_task => :environment) do
      Stagehand::Database.each do |connection_name|
        Stagehand::Connection.with_production_writes do
          puts "#{connection_name}"
          Rake::Task[task].reenable
          Rake::Task[task].invoke
        end
      end
      Rake::Task[task].clear
    end

    # Enhance the original task to run the stagehand_task as a prerequisite
    Rake::Task[task].enhance(["stagehand:#{stagehand_task}"]) unless Stagehand::Configuration.single_connection?
  end

  rake_both_databases('db:create')
  rake_both_databases('db:migrate')
  rake_both_databases('db:migrate:up')
  rake_both_databases('db:migrate:down')
  rake_both_databases('db:rollback')
  rake_both_databases('db:test:load_structure')
  rake_both_databases('db:test:load_schema')
end

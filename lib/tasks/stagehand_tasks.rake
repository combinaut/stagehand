require 'stagehand/rake_helpers'

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

  Stagehand::RakeHelpers.rake_both_databases('db:create')
  Stagehand::RakeHelpers.rake_both_databases('db:migrate')
  Stagehand::RakeHelpers.rake_both_databases('db:migrate:up')
  Stagehand::RakeHelpers.rake_both_databases('db:migrate:down')
  Stagehand::RakeHelpers.rake_both_databases('db:rollback')
  Stagehand::RakeHelpers.rake_both_databases('db:test:load_schema')
end

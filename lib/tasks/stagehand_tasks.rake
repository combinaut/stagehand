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

  namespace :benchmark do
    desc "Measure the per-iteration cost of Stagehand's shard connection swap. Usage: rake stagehand:benchmark:connection_swap[iterations]"
    task :connection_swap, [:iterations] => :environment do |_t, args|
      iterations = (args[:iterations].presence || 10_000).to_i

      wall = ->{ Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      cpu_clock = defined?(Process::CLOCK_THREAD_CPUTIME_ID) ? Process::CLOCK_THREAD_CPUTIME_ID : Process::CLOCK_PROCESS_CPUTIME_ID
      cpu = ->{ Process.clock_gettime(cpu_clock) }

      measure = ->(label, &blk) do
        # Warmup to avoid JIT/cache skew.
        10.times { blk.call }
        t_wall = wall.call; t_cpu = cpu.call
        iterations.times { blk.call }
        dwall = wall.call - t_wall
        dcpu = cpu.call - t_cpu
        puts format("  %-50s iters=%d  wall=%7.3fs  cpu=%7.3fs  per_iter=%7.1fµs  cpu/wall=%3.0f%%",
                    label, iterations, dwall, dcpu,
                    (dwall / iterations) * 1_000_000,
                    dwall.zero? ? 0 : (dcpu / dwall) * 100)
      end

      puts "Benchmarking connection-swap costs (#{iterations} iterations each):"
      puts "  Rails #{Rails.version}  Ruby #{RUBY_VERSION}  single_connection?=#{Stagehand::Configuration.single_connection?}"

      # 1. No-op block without entering Stagehand's swap helper — pure block-call overhead baseline.
      measure.call("baseline (block call only)") { 1 + 1 }

      # 2. Enter Stagehand's with_staging_connection while already on staging.
      #    Stagehand's own short-circuit in `with_connection` should skip the ActiveRecord.connected_to call.
      Stagehand::Database.with_staging_connection do
        measure.call("with_staging_connection (already-staging short-circuit)") do
          Stagehand::Database.with_staging_connection { }
        end
      end

      # 3. Flip staging <-> production from the default top-level (staging) connection.
      #    This exercises `ActiveRecord::Base.connected_to(shard:, role:)` twice per iter (enter+exit).
      unless Stagehand::Configuration.single_connection?
        measure.call("with_production_connection (staging -> production -> staging)") do
          Stagehand::Database.with_production_connection { }
        end
      end

      # 4. Raw ActiveRecord connected_to swap — bypass Stagehand to see pure AR shard-swap cost.
      #    If this is close to #3, the swap cost is entirely in ActiveRecord (not Stagehand's wrapper).
      measure.call("ActiveRecord::Base.connected_to(shard: :production)") do
        ActiveRecord::Base.connected_to(shard: :production, role: :writing) { }
      end

      measure.call("ActiveRecord::Base.connected_to(shard: :staging)") do
        ActiveRecord::Base.connected_to(shard: :staging, role: :writing) { }
      end

      # 5. Swap + trivial query, to isolate connection-lookup cost vs swap cost.
      measure.call("with_production_connection + SELECT 1") do
        Stagehand::Database.with_production_connection do
          ActiveRecord::Base.connection.select_value("SELECT 1")
        end
      end

      measure.call("with_staging_connection + SELECT 1 (no swap)") do
        Stagehand::Database.with_staging_connection do
          ActiveRecord::Base.connection.select_value("SELECT 1")
        end
      end

      # 6. The cost of the Stagehand probe `connection` resolver (used by Production::Record).
      measure.call("Stagehand::Database::ProductionProbe.connection") do
        Stagehand::Database::ProductionProbe.connection
      end

      measure.call("Stagehand::Database::StagingProbe.connection") do
        Stagehand::Database::StagingProbe.connection
      end

      puts "Done."
    end
  end
end

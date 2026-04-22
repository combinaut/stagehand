require 'spec_helper'
require 'stagehand/staging/synchronizer/profiler'

# Synthetic baselines for the sync code paths. Skipped by default — run with:
#
#   STAGEHAND_BENCHMARK=1 bundle exec rspec spec/benchmarks/synchronizer_benchmark_spec.rb
#
# Each example prints (a) a baseline wall/cpu summary with the profiler off,
# then (b) a profiled run with per-span wall/cpu/count breakdown. Compare
# `cpu/wall` at the top: ~100% means Ruby-bound, ~0% means I/O-bound.
#
# Intended as a reproducible harness for characterizing regressions in the
# gem itself across Rails/Ruby upgrades, independent of any host app.
RSpec.describe 'Synchronizer synthetic benchmarks', :benchmark do
  Profiler = Stagehand::Staging::Synchronizer::Profiler

  # Run `block` three times: once as warmup, once for an un-profiled baseline,
  # once with the profiler attached. `setup` is called before each run so each
  # measurement starts from the same state (important for sync_all since the
  # first run drains the commit entries).
  def bench(label, setup: ->{}, iterations: 1, &block)
    setup.call
    iterations.times(&block) # warmup

    setup.call
    wall0 = Profiler.wall_now
    cpu0 = Profiler.cpu_now
    iterations.times(&block)
    wall = Profiler.wall_now - wall0
    cpu = Profiler.cpu_now - cpu0

    setup.call
    session = Profiler::Session.new(label)
    Thread.current.thread_variable_set(Profiler::SESSION_KEY, session)
    begin
      iterations.times(&block)
    ensure
      Thread.current.thread_variable_set(Profiler::SESSION_KEY, nil)
    end

    puts
    puts "=" * 100
    puts "BENCH: #{label}   (iterations=#{iterations})"
    puts "  env: Rails #{Rails.version}  Ruby #{RUBY_VERSION}  single_connection?=#{Stagehand::Configuration.single_connection?}"
    printf "  baseline (no profiler): wall=%.3fs  cpu=%.3fs  cpu/wall=%.0f%%  per_iter: wall=%.2fms cpu=%.2fms\n",
           wall, cpu, wall.zero? ? 0 : 100.0 * cpu / wall,
           (wall / iterations) * 1000, (cpu / iterations) * 1000
    puts session.report
  end

  # Skip benchmarks unless explicitly requested. Rely on ENV check rather than
  # a global `filter_run_excluding` so a single invocation doesn't affect
  # other specs in the suite.
  before { skip 'set STAGEHAND_BENCHMARK=1 to run' unless ENV['STAGEHAND_BENCHMARK'] }

  # 1000 single-table inserts — the happy path. Establishes sync_all throughput
  # with minimal overhead from table switching or STI resolution.
  it 'sync_all: 1000 inserts into a single table' do
    bench('sync_all / 1000 inserts / 1 table',
          setup: -> { Stagehand::Staging::CommitEntry.delete_all; SourceRecord.delete_all; 1000.times { SourceRecord.create! } }) do
      Stagehand::Staging::Synchronizer.sync_all
    end
  end

  # Same load, but via `sync` which adds the iterate/re-confirm/lock overhead.
  # Comparing against sync_all isolates the cost of autosyncability checks.
  it 'sync: 1000 inserts into a single table' do
    bench('sync / 1000 inserts / 1 table',
          setup: -> { Stagehand::Staging::CommitEntry.delete_all; SourceRecord.delete_all; 1000.times { SourceRecord.create! } }) do
      Stagehand::Staging::Synchronizer.sync
    end
  end

  # Rotates across 4 tables to stress `Production.prepare_to_modify`, which
  # invalidates `Record`'s column cache on every switch. If `reset_column_information`
  # dominates the profile, per-table batching would be a clear win.
  it 'sync_all: 1000 entries across 4 alternating tables' do
    setup = -> do
      Stagehand::Staging::CommitEntry.delete_all
      SourceRecord.delete_all
      TargetAssignment.delete_all
      SerializedColumnRecord.delete_all
      ConstrainedRecord.delete_all
      1000.times do |i|
        case i % 4
        when 0 then SourceRecord.create!
        when 1 then TargetAssignment.create!
        when 2 then SerializedColumnRecord.create!(tags: "tag#{i}")
        when 3 then ConstrainedRecord.create!(unique_number: i)
        end
      end
    end

    bench('sync_all / 1000 entries / 4 tables alternating', setup: setup) do
      Stagehand::Staging::Synchronizer.sync_all
    end
  end

  # Measures sync_now fixed cost + 100-entry commit. Drives the Checklist
  # builder + spider paths which are almost entirely Ruby-side.
  it 'sync_now: 10 invocations of 100-entry commits' do
    bench('sync_now / 10 x 100-entry commits', iterations: 10,
          setup: -> { Stagehand::Staging::CommitEntry.delete_all; SourceRecord.delete_all }) do
      Stagehand::Staging::Synchronizer.sync_now! do
        100.times { SourceRecord.create! }
      end
    end
  end

  # Isolates `CommitEntry.infer_base_class` under a large descendant graph.
  # This method iterates `ActiveRecord::Base.descendants` on every call, which
  # is a known Rails 8 regression suspect for us.
  it 'infer_base_class: 5000 calls with 500 synthetic descendants' do
    # `infer_base_class` calls `klass.name.tableize`, so synthetic classes need
    # real names. Anchor them under a module to avoid polluting the root namespace
    # and so GC can reclaim them after the example.
    stub = Module.new
    stub_const('BenchDescendants', stub)
    500.times do |i|
      stub.const_set("Descendant#{i}", Class.new(ActiveRecord::Base) { self.table_name = 'source_records' })
    end

    bench('CommitEntry.infer_base_class / 500 synthetic descendants', iterations: 500) do
      Stagehand::Staging::CommitEntry.infer_base_class('source_records')
    end
  end

  # Pure shard-swap cost via Stagehand's wrapper. Each iteration does
  # staging -> production -> staging (entry and exit).
  it 'connection swap: 10_000 staging <-> production round trips via Stagehand' do
    skip 'single connection mode — no swap' if Stagehand::Configuration.single_connection?

    bench('Database.with_production_connection / 10k round trips', iterations: 10_000) do
      Stagehand::Database.with_production_connection { }
    end
  end

  # Raw ActiveRecord swap without Stagehand's stack bookkeeping. If this is
  # close to the number above, Stagehand's wrapper is not the overhead.
  it 'connection swap: 10_000 raw ActiveRecord connected_to calls' do
    skip 'single connection mode — no swap' if Stagehand::Configuration.single_connection?

    bench('ActiveRecord::Base.connected_to(shard:, role:) / 10k', iterations: 10_000) do
      ActiveRecord::Base.connected_to(shard: :production, role: :writing) { }
    end
  end

  # Swap + trivial query — how much of real-world per-query cost is the swap
  # vs the query itself.
  it 'connection swap + SELECT 1: 1_000 round trips' do
    skip 'single connection mode — no swap' if Stagehand::Configuration.single_connection?

    bench('with_production_connection + SELECT 1 / 1k', iterations: 1_000) do
      Stagehand::Database.with_production_connection do
        ActiveRecord::Base.connection.select_value('SELECT 1')
      end
    end
  end
end

module Stagehand
  module Staging
    module Synchronizer
      # Opt-in, thread-local profiler for the sync code paths. Measures wall
      # time and CPU time per named span so a run can be characterized as
      # Ruby-bound (cpu ≈ wall) vs I/O-bound (cpu ≪ wall). Designed to be
      # near-zero cost when no session is active — `measure` only pays for one
      # Thread.current lookup on the hot path.
      #
      # Enable via:
      #   STAGEHAND_PROFILE_SYNC=1 (env)
      #   Rails.configuration.x.stagehand.profile_sync = true
      #   Stagehand::Staging::Synchronizer::Profiler.profile { ... } (manual)
      module Profiler
        extend self

        SESSION_KEY = :stagehand_synchronizer_profiler_session

        # Prefer thread CPU so sibling threads (e.g. Sidekiq workers) don't
        # pollute the measurement. Fall back for platforms without it.
        CPU_CLOCK = if defined?(Process::CLOCK_THREAD_CPUTIME_ID)
          Process::CLOCK_THREAD_CPUTIME_ID
        else
          Process::CLOCK_PROCESS_CPUTIME_ID
        end

        Frame = Struct.new(:span, :t_wall, :t_cpu, :child_wall, :child_cpu)

        class Span
          attr_accessor :name, :count, :total_wall, :total_cpu, :self_wall, :self_cpu

          def initialize(name)
            @name = name
            @count = 0
            @total_wall = 0.0
            @total_cpu = 0.0
            @self_wall = 0.0
            @self_cpu = 0.0
          end
        end

        class Session
          attr_reader :label, :started_at_wall, :started_at_cpu, :spans

          def initialize(label)
            @label = label
            @spans = {}
            @stack = []
            @started_at_wall = Profiler.wall_now
            @started_at_cpu = Profiler.cpu_now
          end

          def measure(name)
            span = (@spans[name] ||= Span.new(name))
            frame = Frame.new(span, Profiler.wall_now, Profiler.cpu_now, 0.0, 0.0)
            @stack.push(frame)
            yield
          ensure
            dwall = Profiler.wall_now - frame.t_wall
            dcpu = Profiler.cpu_now - frame.t_cpu
            span.count += 1
            span.total_wall += dwall
            span.total_cpu += dcpu
            span.self_wall += dwall - frame.child_wall
            span.self_cpu  += dcpu  - frame.child_cpu
            @stack.pop
            parent = @stack.last
            if parent
              parent.child_wall += dwall
              parent.child_cpu  += dcpu
            end
          end

          def total_wall
            Profiler.wall_now - @started_at_wall
          end

          def total_cpu
            Profiler.cpu_now - @started_at_cpu
          end

          # Render a summary table sorted by exclusive ("self") CPU time desc
          # so the most Ruby-expensive spans surface first.
          def report
            rows = @spans.values.sort_by {|s| -s.self_cpu }
            lines = []
            lines << "Stagehand Synchronizer Profile: #{label}"
            lines << format("  total: wall=%.3fs cpu=%.3fs (cpu/wall=%.0f%%)",
                            total_wall, total_cpu, fraction(total_cpu, total_wall) * 100)
            lines << format("  %-48s %8s %12s %12s %12s %12s %12s",
                            "span", "count", "self_cpu", "self_wall", "tot_cpu", "tot_wall", "avg_self_cpu")
            rows.each do |s|
              lines << format("  %-48s %8d %11.3fs %11.3fs %11.3fs %11.3fs %10.3fms",
                              s.name.to_s, s.count,
                              s.self_cpu, s.self_wall,
                              s.total_cpu, s.total_wall,
                              s.count.zero? ? 0.0 : (s.self_cpu / s.count) * 1000)
            end
            lines.join("\n")
          end

          private

          def fraction(num, denom)
            denom.zero? ? 0.0 : (num / denom)
          end
        end

        def active?
          !Thread.current.thread_variable_get(SESSION_KEY).nil?
        end

        def current
          Thread.current.thread_variable_get(SESSION_KEY)
        end

        # Wraps a block in a profiling session. Nested calls reuse the outer
        # session so per-span totals aggregate over the whole run.
        def profile(label = 'manual', &block)
          if active?
            return block.call(current)
          end

          session = Session.new(label)
          Thread.current.thread_variable_set(SESSION_KEY, session)
          begin
            block.call(session)
          ensure
            Thread.current.thread_variable_set(SESSION_KEY, nil)
            emit(session)
          end
        end

        # Auto-open a session when the top-level sync entry points run, if
        # profiling is enabled. Called from `Synchronizer.sync*`. No-op if a
        # session is already open (nested call) or if profiling is disabled.
        def auto_profile(label, &block)
          return block.call unless enabled?
          profile(label) { block.call }
        end

        def measure(name, &block)
          session = current
          return block.call unless session
          session.measure(name, &block)
        end

        def enabled?
          return true if ENV['STAGEHAND_PROFILE_SYNC'].to_s == '1'
          return false unless defined?(Rails) && Rails.respond_to?(:configuration)
          !!Rails.configuration.x.stagehand.profile_sync
        rescue NoMethodError
          false
        end

        def wall_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def cpu_now
          Process.clock_gettime(CPU_CLOCK)
        end

        def emit(session)
          message = session.report
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.info(message)
          else
            warn(message)
          end
        end
      end
    end
  end
end

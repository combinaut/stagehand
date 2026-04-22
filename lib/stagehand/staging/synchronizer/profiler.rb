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
      #
      # For long-running syncs, set STAGEHAND_PROFILE_SEGMENT_SECONDS=10
      # (or config.x.stagehand.profile_segment_seconds = 10) to emit per-
      # segment delta reports every N seconds during the run. The delta
      # reports show only the work done *since the previous segment*, so a
      # steady slope in per-call averages across segments reveals a
      # monotonic slowdown that a single cumulative report would hide.
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
          attr_reader :label, :started_at_wall, :started_at_cpu, :spans, :segment_seconds

          def initialize(label, segment_seconds: nil)
            @label = label
            @spans = {}
            @stack = []
            @started_at_wall = Profiler.wall_now
            @started_at_cpu = Profiler.cpu_now
            @segment_seconds = segment_seconds
            @segment_started_at_wall = @started_at_wall
            @segment_started_at_cpu = @started_at_cpu
            @segment_index = 0
            @prev_snapshot = {}
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
            maybe_emit_segment if @segment_seconds
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

          # Force a segment boundary now (used when the session closes so the
          # tail work gets its own segment report instead of being lost).
          def flush_segment!
            return unless @segment_seconds
            emit_segment(final: true)
          end

          private

          def fraction(num, denom)
            denom.zero? ? 0.0 : (num / denom)
          end

          def maybe_emit_segment
            return if Profiler.wall_now - @segment_started_at_wall < @segment_seconds
            emit_segment
          end

          def emit_segment(final: false)
            now_wall = Profiler.wall_now
            now_cpu  = Profiler.cpu_now
            seg_wall = now_wall - @segment_started_at_wall
            seg_cpu  = now_cpu  - @segment_started_at_cpu
            # A flush at close with no elapsed time is redundant with the final
            # cumulative report; skip it.
            return if final && seg_wall < 0.001 && @spans.empty?

            deltas = []
            @spans.each do |name, span|
              prev = @prev_snapshot[name]
              dcount = span.count - (prev ? prev[0] : 0)
              next if dcount.zero?
              deltas << [
                name,
                dcount,
                span.self_cpu  - (prev ? prev[1] : 0.0),
                span.self_wall - (prev ? prev[2] : 0.0),
                span.total_cpu  - (prev ? prev[3] : 0.0),
                span.total_wall - (prev ? prev[4] : 0.0),
              ]
            end
            deltas.sort_by! {|_, _, self_cpu, _, _, _| -self_cpu }

            header = format(
              "Stagehand Synchronizer Profile segment %d [%s] (%.1fs window at t=%.1fs): wall=%.3fs cpu=%.3fs (cpu/wall=%.0f%%)",
              @segment_index, @label, seg_wall, now_wall - @started_at_wall,
              seg_wall, seg_cpu, fraction(seg_cpu, seg_wall) * 100
            )
            table = format("  %-48s %8s %12s %12s %12s %12s %12s",
                           "span", "count", "self_cpu", "self_wall", "tot_cpu", "tot_wall", "avg_self_cpu")
            rows = deltas.map do |name, count, self_cpu, self_wall, total_cpu, total_wall|
              format("  %-48s %8d %11.3fs %11.3fs %11.3fs %11.3fs %10.3fms",
                     name.to_s, count, self_cpu, self_wall, total_cpu, total_wall,
                     count.zero? ? 0.0 : (self_cpu / count) * 1000)
            end
            Profiler.emit_lines([header, table, *rows].join("\n"))

            @prev_snapshot = @spans.transform_values {|s| [s.count, s.self_cpu, s.self_wall, s.total_cpu, s.total_wall] }
            @segment_index += 1
            @segment_started_at_wall = now_wall
            @segment_started_at_cpu = now_cpu
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
        def profile(label = 'manual', segment_seconds: nil, &block)
          if active?
            return block.call(current)
          end

          session = Session.new(label, segment_seconds: segment_seconds)
          Thread.current.thread_variable_set(SESSION_KEY, session)
          begin
            block.call(session)
          ensure
            Thread.current.thread_variable_set(SESSION_KEY, nil)
            session.flush_segment!
            emit(session)
          end
        end

        # Auto-open a session when the top-level sync entry points run, if
        # profiling is enabled. Called from `Synchronizer.sync*`. No-op if a
        # session is already open (nested call) or if profiling is disabled.
        def auto_profile(label, &block)
          return block.call unless enabled?
          profile(label, segment_seconds: segment_seconds_from_config) { block.call }
        end

        def segment_seconds_from_config
          env = ENV['STAGEHAND_PROFILE_SEGMENT_SECONDS']
          return env.to_f if env && env.to_f > 0
          return nil unless defined?(Rails) && Rails.respond_to?(:configuration)
          value = Rails.configuration.x.stagehand.profile_segment_seconds
          return value.to_f if value && value.to_f > 0
          nil
        rescue NoMethodError
          nil
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
          emit_lines(session.report)
        end

        def emit_lines(message)
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

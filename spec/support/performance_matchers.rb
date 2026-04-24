require 'benchmark'

RSpec::Matchers.define :take_less_than do |limit|
  # Accept a positional options hash so the block signature works under
  # RSpec's chain dispatch on Ruby 4.0+ (explicit keyword params or `**opts`
  # in the chain block both raise ArgumentError there).
  chain :over do |opts = {}|
    @samples = opts[:samples]
    @warmup = opts[:warmup]
    @discard_outliers = opts.fetch(:discard_outliers, true)
  end

  chain :seconds do; end

  match do |block|
    @times = []
    @samples ||= 5
    @warmup ||= 1
    @discard_outliers = true if @discard_outliers.nil?

    @warmup.times { block.call }
    @samples.times { @times << Benchmark.realtime(&block) }

    # Discard the highest and lowest times. Skip when doing so would leave
    # fewer than one sample to average, which would otherwise divide-by-zero.
    if @discard_outliers && @times.length > 2
      @times.sort!
      @times.pop
      @times.shift
    end

    @elapsed = @times.sum
    @mean = @times.empty? ? 0.0 : @elapsed / @times.length
    @mean < limit
  end

  failure_message do
    "expected to run in no more than #{expected} seconds but averaged #{@mean.round(2)}s across #{@times.length} sample(s)"
  end

  def supports_block_expectations?
    true
  end
end

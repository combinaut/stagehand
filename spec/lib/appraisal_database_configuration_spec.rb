require 'erb'
require 'yaml'

describe 'appraisal database configuration' do
  let(:database_yml_path) { File.expand_path('../internal/config/database.yml', __dir__) }

  it 'uses the shared database names when no appraisal is active' do
    config = load_database_configuration(
      'STAGEHAND_TEST_DATABASE_SUFFIX' => nil
    )

    expect(config.dig('test', 'database')).to eq('stagehand_staging')
    expect(config.dig('development', 'database')).to eq('stagehand_staging')
    expect(config.dig('production', 'database')).to eq('stagehand_production')
  end

  it 'suffixes database names when an appraisal suffix is provided' do
    config = load_database_configuration(
      'STAGEHAND_TEST_DATABASE_SUFFIX' => '_rails_8_1'
    )

    expect(config.dig('test', 'database')).to eq('stagehand_staging_rails_8_1')
    expect(config.dig('development', 'database')).to eq('stagehand_staging_rails_8_1')
    expect(config.dig('production', 'database')).to eq('stagehand_production_rails_8_1')
  end

  it 'prefers an explicit database suffix override' do
    config = load_database_configuration(
      'STAGEHAND_TEST_DATABASE_SUFFIX' => '_custom_parallel_suffix'
    )

    expect(config.dig('test', 'database')).to eq('stagehand_staging_custom_parallel_suffix')
    expect(config.dig('development', 'database')).to eq('stagehand_staging_custom_parallel_suffix')
    expect(config.dig('production', 'database')).to eq('stagehand_production_custom_parallel_suffix')
  end

  def load_database_configuration(environment)
    with_environment(environment) do
      YAML.safe_load(ERB.new(File.read(database_yml_path)).result)
    end
  end

  def with_environment(environment)
    previous_values = environment.each_with_object({}) do |(key, value), values|
      values[key] = ENV[key]

      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end

    yield
  ensure
    previous_values.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
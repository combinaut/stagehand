require 'rake'
require 'securerandom'

Rails.application.load_tasks

describe "Stagehand Tasks" do
  describe "stagehand:migration" do
    without_transactional_fixtures

    it 'should migrate both tables' do
      expect { Rake::Task['db:migrate'].invoke }.to change{ find_database_versions }.to(["1", "1"])
    end

    it 'should rollback both tables' do
      Rake::Task['db:migrate']
      expect { Rake::Task['db:rollback'].invoke }.to change{ find_database_versions }.to(["0", "0"])
    end

    def find_database_versions
      [Stagehand::Database.production_database_versions.last, Stagehand::Database.staging_database_versions.last]
    end
  end

  describe Stagehand::RakeHelpers do
    it 'creates both configured databases explicitly for db:create' do
      allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:create)

      Rake::Task['db:create'].reenable
      Rake::Task['stagehand:db_create'].reenable
      Rake::Task['db:create'].invoke

      expect(ActiveRecord::Tasks::DatabaseTasks).to have_received(:create).with(Stagehand.configuration.production_connection_name).once
      expect(ActiveRecord::Tasks::DatabaseTasks).to have_received(:create).with(Stagehand.configuration.staging_connection_name).once
    end

    it 'runs the original task prerequisites when invoking the original task' do
      task_suffix = SecureRandom.hex(4)
      prerequisite_task = "test:prerequisite:#{task_suffix}"
      original_task = "test:task:#{task_suffix}"
      wrapped_task = "test_task_#{task_suffix}"
      calls = []

      Rake::Task.define_task(prerequisite_task) do
        calls << :prerequisite
      end

      Rake::Task.define_task(original_task => prerequisite_task) do
        calls << :task
      end

      Rake.application.in_namespace(:stagehand) do
        described_class.rake_both_databases(original_task, wrapped_task)
      end

      Rake::Task[original_task].invoke

      expect(calls).to include(:prerequisite)
    ensure
      [prerequisite_task, original_task, "stagehand:#{wrapped_task}"].compact.each do |task_name|
        Rake::Task[task_name].clear if Rake::Task.task_defined?(task_name)
      end
    end

    it 'preserves the original task prerequisites when the task is reenabled and invoked again' do
      task_suffix = SecureRandom.hex(4)
      prerequisite_task = "test:prerequisite:#{task_suffix}"
      original_task = "test:task:#{task_suffix}"
      wrapped_task = "test_task_#{task_suffix}"
      calls = []

      Rake::Task.define_task(prerequisite_task) do
        calls << :prerequisite
      end

      Rake::Task.define_task(original_task => prerequisite_task) do
        calls << :task
      end

      Rake.application.in_namespace(:stagehand) do
        described_class.rake_both_databases(original_task, wrapped_task)
      end

      Rake::Task[original_task].invoke
      Rake::Task[original_task].reenable
      Rake::Task[prerequisite_task].reenable
      Rake::Task["stagehand:#{wrapped_task}"].reenable
      Rake::Task[original_task].invoke

      expect(calls.count(:prerequisite)).to eq(2)
    ensure
      [prerequisite_task, original_task, "stagehand:#{wrapped_task}"].compact.each do |task_name|
        Rake::Task[task_name].clear if Rake::Task.task_defined?(task_name)
      end
    end
  end
end

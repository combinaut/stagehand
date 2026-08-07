require 'spec_helper'

describe Stagehand::Schema do
  # 41 characters, long enough to push the generated trigger name past the mysql identifier limit
  let(:long_table_name) { 'records_with_an_extremely_long_table_name' }

  def trigger_name(table_name, trigger_event = 'insert')
    Stagehand::Schema.send(:trigger_name, table_name, trigger_event)
  end

  describe '::trigger_name' do
    it 'includes the event and the table name' do
      expect(trigger_name('widgets', 'update')).to eq('stagehand_update_trigger_widgets')
    end

    it 'downcases the name' do
      expect(trigger_name('Widgets')).to eq('stagehand_insert_trigger_widgets')
    end

    it 'does not truncate names that fit within the mysql identifier limit' do
      table_name = 'a' * 39
      expect(trigger_name(table_name)).to eq("stagehand_insert_trigger_#{table_name}")
    end

    it 'truncates names that exceed the mysql identifier limit' do
      expect(trigger_name(long_table_name).length).to eq(Stagehand::Schema::MYSQL_IDENTIFIER_LIMIT)
    end

    it 'retains the prefix trigger detection matches on when truncating' do
      expect(trigger_name(long_table_name)).to start_with('stagehand_insert_trigger_')
    end

    # Locked to literals because triggers are created by one process and looked up and dropped by another, so the name
    # a table maps to has to be stable across processes and releases. Changing the truncation or the digest orphans
    # every trigger already created for a table name over the limit, and `drop_trigger` fails silently when it happens.
    it 'appends a digest of the untruncated name to the truncated name' do
      expect(trigger_name(long_table_name, 'insert')).to eq('stagehand_insert_trigger_records_with_an_extremely_long_8017cd4a')
      expect(trigger_name(long_table_name, 'update')).to eq('stagehand_update_trigger_records_with_an_extremely_long_2576aa2e')
      expect(trigger_name(long_table_name, 'delete')).to eq('stagehand_delete_trigger_records_with_an_extremely_long_94ac3fe5')
    end

    it 'does not collide for long table names sharing a prefix' do
      expect(trigger_name("#{long_table_name}_a")).not_to eq(trigger_name("#{long_table_name}_b"))
    end

    it 'does not collide for different events on the same long table name' do
      expect(trigger_name(long_table_name, 'insert')).not_to eq(trigger_name(long_table_name, 'update'))
    end
  end

  describe 'tracking a table whose name exceeds the trigger name limit' do
    without_transactional_fixtures

    before do
      table_name = long_table_name
      ActiveRecord::Schema.define { create_table(table_name, :force => true, :stagehand => true) }
    end

    after do
      table_name = long_table_name
      ActiveRecord::Schema.define { drop_table(table_name, :if_exists => true) }
    end

    it 'creates the triggers' do
      expect(Stagehand::Schema.has_stagehand?(long_table_name)).to be true
    end

    it 'logs commit entries when records are written' do
      expect { ActiveRecord::Base.connection.execute("INSERT INTO #{long_table_name} (id) VALUES (1)") }
        .to change { Stagehand::Staging::CommitEntry.insert_operations.where(:table_name => long_table_name).count }
        .by(1)
    end

    it 'drops the triggers' do
      expect { Stagehand::Schema.remove_stagehand!(:only => long_table_name) }
        .to change { Stagehand::Schema.has_stagehand?(long_table_name) }
        .to(false)
    end
  end
end

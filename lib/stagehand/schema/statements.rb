module Stagehand
  module Schema
    module Statements
      # Ensure that developers are aware they need to make a determination of whether stagehand should track this table or not
      def create_table(table_name, stagehand: nil, **options)
        super(table_name, **options)

        return if Database.connected_to_production? && !Stagehand::Configuration.single_connection?
        return if stagehand == false
        return if UNTRACKED_TABLES.include?(table_name)

        Schema.add_stagehand! :only => table_name
      end

      def rename_table(old_table_name, new_table_name, *, **)
        return super unless Schema.has_stagehand?(old_table_name)

        Schema.remove_stagehand!(:only => old_table_name, :remove_entries => false)
        super
        Schema.add_stagehand!(:only => new_table_name)
        Staging::CommitEntry.where(:table_name => old_table_name).update_all(:table_name => new_table_name)
      end

      def drop_table(table_name, *, **)
        return super unless Schema.has_stagehand?(table_name) && table_exists?(Staging::CommitEntry.table_name)

        Schema.remove_stagehand!(:only => table_name, :remove_entries => true)
        super
      end
    end

    # Allow dumping of stagehand create_table directive
    # e.g. create_table "comments", stagehand: true do |t|
    module DumperExtensions
      def table(table_name, stream)
        stagehand = Stagehand::Schema.has_stagehand?(table_name)
        stagehand = ':commit_entries' if table_name == Staging::CommitEntry.table_name

        table_stream = StringIO.new
        super(table_name, table_stream)
        table_stream.rewind
        table_schema = table_stream.read.gsub(/create_table (.+) do/, 'create_table \1' + ", stagehand: #{stagehand} do")
        stream.puts table_schema

        return stream
      end
    end
  end
end

ActiveRecord::Base.connection.class.include Stagehand::Schema::Statements
ActiveRecord::SchemaDumper.prepend Stagehand::Schema::DumperExtensions

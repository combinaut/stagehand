module Stagehand
  module Schema
    module Statements
      # Ensure that developers are aware they need to make a determination of whether stagehand should track this table or not
      def create_table(table_name, options = {})
        super
        options = options.symbolize_keys

        return if Database.connected_to_production? && !Stagehand::Configuration.single_connection?
        return Schema.send(:create_session_trigger) if options[:stagehand] == :commit_entries
        return if options[:stagehand] == false
        return if UNTRACKED_TABLES.include?(table_name)

        Schema.add_stagehand! :only => table_name
      end

      def rename_table(old_table_name, new_table_name, *)
        return super unless Schema.has_stagehand?(old_table_name)

        Schema.remove_stagehand!(:only => old_table_name)
        super
        Schema.add_stagehand!(:only => new_table_name)
        Staging::CommitEntry.where(:table_name => old_table_name).update_all(:table_name => new_table_name)
      end

      def drop_table(table_name, *)
        return super unless Schema.has_stagehand?(table_name) && table_exists?(Staging::CommitEntry.table_name)

        super
        Staging::CommitEntry.where(:table_name => table_name).delete_all
        Staging::Commit.empty.each(&:destroy)
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

begin
  ActiveRecord::Base.connection.class.include Stagehand::Schema::Statements
rescue ActiveRecord::NoDatabaseError => e
  Rails.logger.debug("#{e.class.name}, #{e.to_s} - continuing anyway, as we expect DB creation")
end

ActiveRecord::SchemaDumper.prepend Stagehand::Schema::DumperExtensions

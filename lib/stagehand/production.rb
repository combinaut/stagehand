require 'stagehand/production/controller'

module Stagehand
  module Production
    extend self

    # Outputs a symbol representing the status of the staging record as it exists in the production database
    def status(staging_record, table_name = nil)
      if !exists?(staging_record, table_name)
        :new
      elsif modified?(staging_record, table_name)
        :modified
      else
        :not_modified
      end
    end

    def save(staging_record, table_name = nil)
      Stagehand::Staging::Synchronizer::Profiler.measure(:Production_save) do
        attributes = Stagehand::Staging::Synchronizer::Profiler.measure(:Production_save__staging_attrs) do
          staging_record_attributes(staging_record, table_name)
        end

        next unless attributes.present?

        write(staging_record, attributes, table_name)
      end
    end

    def write(staging_record, attributes, table_name = nil)
      Stagehand::Staging::Synchronizer::Profiler.measure(:Production_write) do
        table_name, id = Stagehand::Key.generate(staging_record, :table_name => table_name)

        Connection.with_production_writes do
          prepare_to_modify(table_name)

          if Stagehand::Staging::Synchronizer::Profiler.measure(:Production_update) { update(table_name, id, attributes) }.nonzero?
            Record.find(id)
          else
            Record.find(Stagehand::Staging::Synchronizer::Profiler.measure(:Production_insert) { insert(table_name, attributes) })
          end
        end
      end
    end

    def delete(staging_record, table_name = nil)
      Stagehand::Staging::Synchronizer::Profiler.measure(:Production_delete) do
        Connection.with_production_writes do
          matching(staging_record, table_name).delete_all
        end
      end
    end

    def exists?(staging_record, table_name = nil)
      matching(staging_record, table_name).exists?
    end

    # Returns true if the staging record's attributes are different from the production record's attributes
    # Returns true if the staging_record does not exist on production
    # Returns false if the staging record is identical to the production record
    def modified?(staging_record, table_name = nil)
      production_record_attributes(staging_record, table_name) != staging_record_attributes(staging_record, table_name)
    end

    def find(*args)
      matching(*args).first
    end

    # Returns a scope that limits results any occurrences of the specified record.
    # Record can be specified by passing a staging record, or an id and table_name.
    def matching(staging_record, table_name = nil)
      table_name, id = Stagehand::Key.generate(staging_record, :table_name => table_name)
      prepare_to_modify(table_name)
      return Record.where(:id => id)
    end

    private

    def production_record_attributes(staging_record, table_name = nil)
      Record.connection.select_one(matching(staging_record, table_name))
    end

    def staging_record_attributes(staging_record, table_name = nil)
      table_name, id = Stagehand::Key.generate(staging_record, :table_name => table_name)
      hash = select(table_name, id)
      hash.except(*ignored_columns(table_name)) if hash
    end

    def ignored_columns(table_name)
      Array.wrap(Configuration.ignored_columns[table_name]).map(&:to_s)
    end

    def select(table_name, id)
      table = Arel::Table.new(table_name)
      statement = Arel::SelectManager.new
      statement.from table
      statement.project Arel.star
      statement.where table[:id].eq(id)

      Stagehand::Database::StagingProbe.connection.select_one(statement)
    end

    def update(table_name, id, attributes)
      table = Arel::Table.new(table_name)
      statement = Arel::UpdateManager.new
      statement.table table
      statement.set attributes.map {|attribute, value| [table[attribute], value] }
      statement.where table[:id].eq(id)

      Record.connection.update(statement)
    end

    def insert(table_name, attributes)
      table = Arel::Table.new(table_name)
      statement = Arel::InsertManager.new
      statement.into table
      statement.insert attributes.map {|attribute, value| [table[attribute], value] }

      Record.connection.insert(statement)
    end

    def prepare_to_modify(table_name)
      Stagehand::Staging::Synchronizer::Profiler.measure(:Production_prepare_to_modify) do
        raise "Can't prepare to modify production records without knowning the table_name" unless table_name.present?

        next if Record.table_name == table_name

        Stagehand::Staging::Synchronizer::Profiler.measure(:Production_reset_column_information) do
          Record.table_name = table_name
          Record.reset_column_information
        end
      end
    end

    # CLASSES

    class Record < Stagehand::Database::ProductionProbe
      self.record_timestamps = false
      self.inheritance_column = nil
    end
  end
end

require 'stagehand/auditor/checklist_visualizer'

module Stagehand
  module Auditor
    extend self

    def incomplete_commits
      incomplete = []

      incomplete_commit_ids.each do |commit_id|
        incomplete << [commit_id, Staging::CommitEntry.where(:commit_id => commit_id)]
      end

      return incomplete.to_h
    end

    def mismatched_records(options = {})
      output = {}

      tables = options[:tables] || Database.staging_connection.tables.select {|table_name| Schema::has_stagehand?(table_name) }
      Array(tables).each do |table_name|
        print "\nChecking #{table_name} "
        mismatched = Hash.new {|k,v| k[v] = {} }
        limit = 1000

        min_id = [
          Database.staging_connection.select_value("SELECT MIN(id) FROM #{table_name}").to_i,
          Database.production_connection.select_value("SELECT MIN(id) FROM #{table_name}").to_i
        ].min

        index = min_id / limit

        max_id = [
          Database.staging_connection.select_value("SELECT MAX(id) FROM #{table_name}").to_i,
          Database.production_connection.select_value("SELECT MAX(id) FROM #{table_name}").to_i
        ].max

        loop do
          production_records = Database.production_connection.select_all("SELECT * FROM #{table_name} WHERE id BETWEEN #{limit * index} AND #{limit * (index + 1)}")
          staging_records = Database.staging_connection.select_all("SELECT * FROM #{table_name} WHERE id BETWEEN #{limit * index} AND #{limit * (index + 1)}")
          id_column = production_records.columns.index('id')

          production_differences = production_records.rows - staging_records.rows
          staging_differences = staging_records.rows - production_records.rows

          production_differences.each do |row|
            id = row[id_column]
            mismatched[id][:production] = row
          end
          staging_differences.each do |row|
            id = row[id_column]
            mismatched[id][:staging] = row
          end

          if production_differences.present? || staging_differences.present?
            print '!'
          else
            print '.'
          end

          index += 1

          break if index * limit > max_id
        end

        if mismatched.present?
          print " #{mismatched.count} mismatched"
          output[table_name] = mismatched
        end
      end

      return output
    end

    def visualize(subject, output_file_name, options = {})
      visualize_checklist(Staging::Checklist.new(subject), output_file_name, options)
    end

    def visualize_checklist(checklist, output_file_name, options = {})
      ChecklistVisualizer.new(checklist, options).output(output_file_name)
    end

    private

    # Commit that is missing a start or end operation
    def incomplete_commit_ids
      Staging::CommitEntry.control_operations.group(:commit_id).having("count(*) != 2").pluck(Arel.sql("MIN(commit_id)"))
    end
  end
end

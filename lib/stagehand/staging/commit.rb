module Stagehand
  module Staging
    class Commit
      def self.all
        CommitEntry.start_operations.committed.pluck(:commit_id).collect {|id| find(id) }.compact
      end

      def self.empty
        all.select(&:empty?)
      end

      def self.capturing?
        !!@capturing
      end

      def self.capture(subject_record = nil, except: [], &block)
        @capturing = true
        start_operation = start_commit(subject_record)
        set_session_commit_id(start_operation.commit_id)

        begin
          block.call(start_operation)
          start_operation.subject = subject_record if !start_operation.record_id? && subject_record&.persisted? # Set the subject if it wasn't persisted when the commit started, but now it is.
        rescue Exception => e # Rescue Exception because we don't want to swallow them by returning from the ensure block
          raise(e)
        ensure
          commit = end_commit(start_operation, except) unless e.is_a?(CommitError) || e.is_a?(ActiveRecord::Rollback)
          set_session_commit_id(nil) # Stop recording entries to this commit
          return commit unless e
        end

      ensure
        @capturing = false
      end

      def self.containing(record)
        find(CommitEntry.contained.matching(record).pluck(:commit_id))
      end

      def self.find(start_ids)
        if start_ids.respond_to?(:each)
          start_ids.to_a.uniq.collect {|id| find(id) }.compact
        else
          new(start_ids)
        end
      rescue CommitNotFound
      end

      private

      def self.start_commit(subject_record)
        start_operation = CommitEntry.start_operations.new

        # Make it easy to set the subject for the duration of the commit block
        def start_operation.subject=(record)
          if record&.id
            raise NonStagehandSubject unless record.has_stagehand?
            self.assign_attributes :record_id => record.id, :table_name => record.class.table_name
          end
          save!
        end

        start_operation.subject = subject_record

        return start_operation
      end

      # Sets the commit_id on all the entries between the start and end op.
      # Returns the commit object for those entries
      def self.end_commit(start_operation, except)
        scope = CommitEntry.where(:commit_id => start_operation.id)

        # Remove any commit entries that are supposed to be excluded from the commit
        if except.present? && Array(except).collect(&:to_s).exclude?(start_operation.table_name)
          scope.content_operations.where(:table_name => except).update_all(:commit_id => nil)
        end

        end_operation = scope.end_operations.create
        entries = scope.to_a

        if entries.count(&:control_operation?) < 2 # Unless we found at least 2 entries (start and end), abort the commit
          CommitEntry.logger.warn "Commit entries not found for Commit #{start_operation.id}. Was the Commit rolled back in a transaction?"
          return nil
        elsif entries.none?(&:content_operation?) # Destroy empty commit
          scope.delete_all
          return nil
        else
          CommitEntry.where(id: entries.map(&:id)).update_all(:committed => true) # Allow these entries to be considered when spidering and determining auto syncing.
          return new(start_operation.id)
        end
      end

      # Ensure all entries created on this connection from now on match the given commit_id
      def self.set_session_commit_id(commit_id)
        CommitEntry.connection.execute <<~SQL
          SET @stagehand_commit_id = #{commit_id || 'NULL'};
        SQL
      end

      public

      def initialize(start_id)
        @start_id, @end_id = CommitEntry.control_operations
          .limit(2)
          .where(:commit_id => start_id)
          .where('id >= ?', start_id)
          .reorder(:id => :asc)
          .pluck(:id)

        return if @start_id && @end_id

        missing = []
        missing << CommitEntry::START_OPERATION unless @start_id == start_id
        missing << CommitEntry::END_OPERATION if @start_id == start_id

        raise CommitNotFound, "Couldn't find #{missing.join(', ')} entry for Commit #{start_id}"
      end

      def id
        @start_id
      end

      def include?(record)
        entries.where(:record_id => record.id, :table_name => record.class.table_name).exists?
      end

      def hash
        id
      end

      def eql?(other)
        self == other
      end

      def ==(other)
        id == other.id
      end

      def subject
        start_entry.record
      end

      def start_entry
        CommitEntry.find(@start_id)
      end

      def end_entry
        entries.end_operations.first
      end

      def empty?
        entries.content_operations.empty?
      end

      def destroy
        entries.delete_all
      end

      def entries
        CommitEntry.where(:id => @start_id..@end_id).where(:commit_id => id)
      end
    end
  end

  # EXCEPTIONS
  class CommitError < StandardError; end
  class CommitNotFound < CommitError; end
  class NonStagehandSubject < CommitError; end
end

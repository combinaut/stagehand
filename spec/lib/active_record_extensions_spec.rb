describe 'ActiveRecordExtensions' do
  class ConnectionTestMock < SourceRecord; end
  let(:source_record) { SourceRecord.create }

  describe '#synced?' do
    it 'returns false when there are unsynced changes' do
      expect(source_record.synced?).to be(false)
    end

    it 'returns true when there are no unsynced changes' do
      Stagehand::Staging::Synchronizer.sync_record(source_record)
      expect(source_record.synced?).to be(true)
    end
  end

  describe '#synced_all_commits?' do
    it 'returns false when there are unsynced commits' do
      Stagehand::Staging::Commit.capture { source_record.touch }
      expect(source_record.synced_all_commits?).to be(false)
    end

    it 'returns true when there are unsynced commit entries without a commit' do
      source_record.touch
      expect(source_record.synced_all_commits?).to be(true)
    end
  end
end

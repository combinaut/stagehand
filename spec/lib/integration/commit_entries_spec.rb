describe 'commit entries' do
  let(:klass) { Stagehand::Staging::CommitEntry }
  let(:source_record) { SourceRecord.create }
  subject { source_record; Stagehand::Staging::CommitEntry.last }

  it 'sets the timestamp to the correct timezone' do
    expect(subject).to have_attributes(:created_at => be_within(2.seconds).of(Time.current))
  end
end

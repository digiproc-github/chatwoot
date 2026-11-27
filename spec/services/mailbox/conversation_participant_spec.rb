require 'rails_helper'

RSpec.describe Mailbox::ConversationParticipant do
  let(:account) { create(:account) }
  let(:email_channel) { create(:channel_email, email: 'support@example.com', account: account) }
  let(:customer) { create(:contact, email: 'customer@example.com', account: account) }
  let(:conversation) { create(:conversation, inbox: email_channel.inbox, account: account, contact: customer) }

  before do
    create(:message, conversation: conversation, account: account, inbox: email_channel.inbox, message_type: :incoming,
                     content_attributes: {
                       email: { from: ['customer@example.com'], to: ['support@example.com', 'colleague@example.com'], cc: ['manager@example.com'],
                                bcc: ['customer-bcc@example.com'] },
                       cc_email: ['manager@example.com'],
                       bcc_email: ['customer-bcc@example.com']
                     })
    create(:message, conversation: conversation, account: account, inbox: email_channel.inbox, message_type: :outgoing,
                     content_attributes: { to_emails: ['recipient@example.com'], cc_emails: ['agent-cc@example.com'],
                                           bcc_emails: ['agent-bcc@example.com'] })
    create(:message, conversation: conversation, account: account, inbox: email_channel.inbox, message_type: :outgoing, private: true,
                     content_attributes: { cc_emails: ['note-only@example.com'] })
  end

  def participant?(email)
    described_class.new(conversation, email).participant?
  end

  it 'treats the conversation contact as a participant, ignoring case' do
    expect(participant?('Customer@Example.com')).to be true
  end

  it 'treats To and CC recipients of incoming emails as participants' do
    expect(participant?('colleague@example.com')).to be true
    expect(participant?('manager@example.com')).to be true
  end

  it 'treats To and CC recipients of agent replies as participants' do
    expect(participant?('recipient@example.com')).to be true
    expect(participant?('agent-cc@example.com')).to be true
  end

  it 'does not treat BCC recipients as participants' do
    expect(participant?('customer-bcc@example.com')).to be false
    expect(participant?('agent-bcc@example.com')).to be false
  end

  it 'ignores addresses that only appear on private notes' do
    expect(participant?('note-only@example.com')).to be false
  end

  it 'does not treat unknown senders as participants' do
    expect(participant?('stranger@example.com')).to be false
  end
end

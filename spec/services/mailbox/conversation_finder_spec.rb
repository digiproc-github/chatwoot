require 'rails_helper'

RSpec.describe Mailbox::ConversationFinder do
  let(:account) { create(:account) }
  let(:email_channel) { create(:channel_email, email: 'test@example.com', account: account) }
  let(:conversation) { create(:conversation, inbox: email_channel.inbox, account: account) }
  let(:mail) { Mail.new }

  describe '#find' do
    context 'when receiver uuid strategy finds conversation' do
      before do
        conversation.update!(uuid: '12345678-1234-1234-1234-123456789012')
        mail.to = 'reply+12345678-1234-1234-1234-123456789012@example.com'
      end

      it 'returns the conversation' do
        finder = described_class.new(mail)
        expect(finder.find).to eq(conversation)
      end

      it 'logs which strategy succeeded' do
        allow(Rails.logger).to receive(:info)
        finder = described_class.new(mail)
        finder.find

        expect(Rails.logger).to have_received(:info).with('Conversation found via receiver_uuid_strategy strategy')
      end
    end

    context 'when in_reply_to strategy finds conversation' do
      before do
        conversation.update!(uuid: '12345678-1234-1234-1234-123456789012')
        mail.in_reply_to = 'conversation/12345678-1234-1234-1234-123456789012/messages/123@example.com'
      end

      it 'returns the conversation' do
        finder = described_class.new(mail)
        expect(finder.find).to eq(conversation)
      end

      it 'logs which strategy succeeded' do
        allow(Rails.logger).to receive(:info)
        finder = described_class.new(mail)
        finder.find

        expect(Rails.logger).to have_received(:info).with('Conversation found via in_reply_to_strategy strategy')
      end
    end

    context 'when references strategy finds conversation' do
      before do
        conversation.update!(uuid: '12345678-1234-1234-1234-123456789012')
        mail.to = 'test@example.com'
        mail.references = 'conversation/12345678-1234-1234-1234-123456789012/messages/123@example.com'
      end

      it 'returns the conversation' do
        finder = described_class.new(mail)
        expect(finder.find).to eq(conversation)
      end

      it 'logs which strategy succeeded' do
        allow(Rails.logger).to receive(:info)
        finder = described_class.new(mail)
        finder.find

        expect(Rails.logger).to have_received(:info).with('Conversation found via references_strategy strategy')
      end
    end

    context 'when no strategy finds conversation' do
      # With NewConversationStrategy in default strategies, this scenario only happens
      # when using custom strategies that exclude NewConversationStrategy
      let(:finding_strategies) do
        [
          Mailbox::ConversationFinderStrategies::ReceiverUuidStrategy,
          Mailbox::ConversationFinderStrategies::InReplyToStrategy,
          Mailbox::ConversationFinderStrategies::ReferencesStrategy
        ]
      end

      it 'returns nil' do
        finder = described_class.new(mail, strategies: finding_strategies)
        expect(finder.find).to be_nil
      end

      it 'logs that no conversation was found' do
        allow(Rails.logger).to receive(:error)
        finder = described_class.new(mail, strategies: finding_strategies)
        finder.find

        expect(Rails.logger).to have_received(:error).with('No conversation found via any strategy (NewConversationStrategy missing?)')
      end
    end

    context 'with custom strategies' do
      let(:custom_strategy_class) do
        Class.new(Mailbox::ConversationFinderStrategies::BaseStrategy) do
          def find
            # Always return nil for testing
            nil
          end
        end
      end

      it 'uses provided strategies instead of defaults' do
        finder = described_class.new(mail, strategies: [custom_strategy_class])
        expect(finder.find).to be_nil
      end
    end

    context 'with strategy execution order' do
      before do
        conversation.update!(uuid: '12345678-1234-1234-1234-123456789012')

        # Set up mail so all strategies could match
        mail.to = 'reply+12345678-1234-1234-1234-123456789012@example.com'
        mail.in_reply_to = 'conversation/12345678-1234-1234-1234-123456789012/messages/123@example.com'
        mail.references = 'conversation/12345678-1234-1234-1234-123456789012/messages/456@example.com'
      end

      it 'returns conversation from first matching strategy' do
        allow(Rails.logger).to receive(:info)
        finder = described_class.new(mail)
        result = finder.find

        expect(result).to eq(conversation)
        # Should only log the first strategy that succeeded (ReceiverUuidStrategy)
        expect(Rails.logger).to have_received(:info).once.with('Conversation found via receiver_uuid_strategy strategy')
      end
    end

    context 'when the sender was not visible on the matched conversation' do
      let(:customer) { create(:contact, email: 'customer@example.com', account: account) }
      let(:conversation) { create(:conversation, inbox: email_channel.inbox, account: account, contact: customer) }

      before do
        conversation.update!(uuid: '12345678-1234-1234-1234-123456789012')
        create(:message, conversation: conversation, account: account, inbox: email_channel.inbox, message_type: :outgoing,
                         content_attributes: { cc_emails: ['visible@example.com'], bcc_emails: ['hidden@example.com'] })
        mail.to = 'reply+12345678-1234-1234-1234-123456789012@example.com'
      end

      it 'builds a new conversation for the sender in the same inbox' do
        mail.from = 'hidden@example.com'
        result = described_class.new(mail).find

        expect(result).to be_new_record
        expect(result.inbox).to eq(email_channel.inbox)
        expect(result.contact.email).to eq('hidden@example.com')
        expect(result.additional_attributes['split_from_conversation_id']).to eq(conversation.id)
      end

      it 'returns the conversation an earlier email from the sender was split into' do
        mail.from = 'hidden@example.com'
        hidden_contact = create(:contact, email: 'hidden@example.com', account: account)
        split_conversation = create(:conversation, inbox: email_channel.inbox, account: account, contact: hidden_contact,
                                                   additional_attributes: { split_from_conversation_id: conversation.id })

        expect(described_class.new(mail).find).to eq(split_conversation)
      end

      it 'returns the matched conversation for a CC recipient' do
        mail.from = 'visible@example.com'
        expect(described_class.new(mail).find).to eq(conversation)
      end

      it 'returns the matched conversation for its contact' do
        mail.from = 'Customer@Example.com'
        expect(described_class.new(mail).find).to eq(conversation)
      end
    end
  end
end

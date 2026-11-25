# Links a conversation that was split off for a sender who was not visible on the original thread
# (for example a BCC recipient) back to the conversation the email replied to, so agents have its context.
class Mailbox::OriginContext
  SPLIT_FROM_KEY = 'split_from_conversation_id'.freeze

  # The conversation that an earlier email from this contact on the same thread was split into
  def self.split_conversation_for(contact, origin)
    contact.conversations.where(inbox_id: origin.inbox_id).detect do |conversation|
      conversation.additional_attributes[SPLIT_FROM_KEY] == origin.id
    end
  end

  def initialize(conversation)
    @conversation = conversation
    @origin = conversation.account.conversations.find(conversation.additional_attributes[SPLIT_FROM_KEY])
  end

  def perform
    create_activity_message
    create_original_message_note
  end

  private

  def create_activity_message
    @conversation.messages.create!(
      message_type: :activity,
      content: I18n.t('conversations.activity.email_split.originated_from', display_id: @origin.display_id),
      content_attributes: { originated_from_conversation_id: @origin.display_id },
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id
    )
  end

  def create_original_message_note
    original_message = @origin.messages.incoming.order(:created_at).first
    return if original_message.blank?

    content = I18n.t('conversations.activity.email_split.original_message', display_id: @origin.display_id, content: original_message.content)
    @conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      content: content.truncate(150_000),
      content_attributes: { originated_from_conversation_id: @origin.display_id, email: original_message.content_attributes['email'] },
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: original_message.sender
    )
  end
end

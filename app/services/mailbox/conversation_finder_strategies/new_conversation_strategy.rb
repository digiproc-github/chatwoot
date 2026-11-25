class Mailbox::ConversationFinderStrategies::NewConversationStrategy < Mailbox::ConversationFinderStrategies::BaseStrategy
  include MailboxHelper
  include IncomingEmailValidityHelper

  attr_accessor :processed_mail, :account, :inbox, :contact, :contact_inbox, :conversation, :channel

  # split_from: a conversation the sender was not visible on (see Mailbox::ConversationFinder).
  # The new conversation goes to that conversation's inbox, because a reply to its reply+uuid address names no inbox address.
  def initialize(mail, split_from: nil)
    super(mail)
    @split_from = split_from
    @channel = split_from.present? ? split_from.inbox.channel : EmailChannelFinder.new(mail).perform
    return unless @channel

    @account = @channel.account
    @inbox = @channel.inbox
    @processed_mail = MailPresenter.new(mail, @account)
  end

  # This strategy prepares a new conversation but doesn't persist it yet.
  # Why we don't use create! here:
  # - Avoids orphan conversations if message/attachment creation fails later
  # - Prevents duplicate conversations on job retry (no idempotency issue)
  # - Follows the pattern from old SupportMailbox where everything was in one transaction
  # The actual persistence happens in ReplyMailbox within a transaction that includes message creation.
  def find
    return nil unless @channel # No valid channel found
    return nil unless incoming_email_from_valid_email? # Skip edge cases

    # Prepare contact (persisted), reuse the sender's conversation for the thread or build one (not persisted)
    find_or_create_contact
    if @split_from.present?
      Mailbox::OriginContext.split_conversation_for(@contact, @split_from) || build_conversation
    else
      find_conversation_by_in_reply_to || build_conversation
    end
  end

  private

  def find_or_create_contact
    @contact = @inbox.contacts.from_email(original_sender_email)
    if @contact.present?
      @contact_inbox = ContactInbox.find_by(inbox: @inbox, contact: @contact)
    else
      create_contact
    end
  end

  def original_sender_email
    sanitize_mailbox_value(@processed_mail.original_sender)&.downcase
  end

  def identify_contact_name
    sanitize_mailbox_value(@processed_mail.sender_name || @processed_mail.from.first.split('@').first)
  end

  def build_conversation
    # Build but don't persist - ReplyMailbox will save in transaction with message
    @conversation = ::Conversation.new(
      account_id: @account.id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: conversation_attributes
    )
  end

  def conversation_attributes
    attributes = {
      in_reply_to: in_reply_to,
      source: 'email',
      auto_reply: @processed_mail.auto_reply?,
      mail_subject: sanitize_mailbox_value(@processed_mail.subject),
      initiated_at: {
        timestamp: Time.now.utc
      }
    }
    attributes[Mailbox::OriginContext::SPLIT_FROM_KEY] = @split_from.id if @split_from.present?
    attributes
  end

  def in_reply_to
    sanitize_mailbox_value(mail['In-Reply-To'].try(:value))
  end

  # Scoped to the sender so replies from different recipients of the same forward stay separate
  def find_conversation_by_in_reply_to
    return if in_reply_to.blank?

    @contact.conversations.where("additional_attributes->>'in_reply_to' = ?", in_reply_to).first
  end
end

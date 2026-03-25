class Imap::ImapMailbox
  include MailboxHelper
  include IncomingEmailValidityHelper
  attr_accessor :channel, :account, :inbox, :conversation, :processed_mail

  FALLBACK_CONVERSATION_PATTERN = %r{account/(\d+)/conversation/([a-zA-Z0-9-]+)@}

  def process(mail, channel)
    @inbound_mail = mail
    @channel = channel
    load_account
    load_inbox
    decorate_mail

    Rails.logger.info("Processing Email from: #{@processed_mail.original_sender} : inbox #{@inbox.id} : message_id #{@processed_mail.message_id}")

    # Skip processing email if it belongs to any of the edge cases
    return unless incoming_email_from_valid_email?

    ActiveRecord::Base.transaction do
      find_or_create_contact
      find_or_create_conversation
      create_message
      add_attachments_to_message
    end
  end

  private

  def load_account
    @account = @channel.account
  end

  def load_inbox
    @inbox = @channel.inbox
  end

  def decorate_mail
    @processed_mail = MailPresenter.new(@inbound_mail, @account)
  end

  def find_conversation_by_in_reply_to
    return if in_reply_to.blank?

    message = @inbox.messages.find_by(source_id: in_reply_to)
    if message.nil?
      @inbox.conversations.find_by("additional_attributes->>'in_reply_to' = ?", in_reply_to)
    else
      @inbox.conversations.find(message.conversation_id)
    end
  end

  def find_conversation_by_reference_ids
    return if @inbound_mail.references.blank?

    message = find_message_by_references
    if message.present?
      conversation = @inbox.conversations.find_by(id: message.conversation_id)
      return conversation if conversation.present?
    end

    # FALLBACK_PATTERN use to find a conversation that is started by an agent (no incoming message yet)
    conversation_id = find_conversation_by_references
    @inbox.conversations.find_by(uuid: conversation_id) if conversation_id.present?
  end

  def in_reply_to
    @processed_mail.in_reply_to
  end

  def find_conversation_by_references
    references = Array.wrap(@inbound_mail.references)
    references.each do |message_id|
      match = FALLBACK_CONVERSATION_PATTERN.match(message_id)

      return match[2] if match.present?
    end
  end

  def find_message_by_references
    message_to_return = nil

    references = Array.wrap(@inbound_mail.references)

    references.each do |message_id|
      message = @inbox.messages.find_by(source_id: message_id)
      message_to_return = message if message.present?
    end
    message_to_return
  end

  def find_or_create_conversation
    existing_conversation = find_conversation_by_in_reply_to || find_conversation_by_reference_ids

    # Verify the sender is a known participant before merging into an existing conversation.
    # BCC recipients share the same In-Reply-To/References headers but should get separate
    # conversations since they were never visible participants in the thread.
    @conversation = if existing_conversation && sender_is_conversation_participant?(existing_conversation)
                      existing_conversation
                    else
                      # The matched conversation failed the participant check (e.g., BCC recipient).
                      # Before creating a new conversation, search all thread-related conversations
                      # for one where the sender IS a participant.
                      find_participant_conversation_from_thread || create_new_conversation(originated_from: existing_conversation)
                    end
  end

  def find_participant_conversation_from_thread
    thread_message_ids = (Array.wrap(@inbound_mail.references) + [in_reply_to]).compact.uniq
    return if thread_message_ids.blank?

    thread_conversations = @inbox.conversations
                                 .joins(:messages)
                                 .where(messages: { source_id: thread_message_ids })
                                 .distinct

    # Fast path: sender already owns a conversation in this thread
    thread_conversations.find_by(contact_id: @contact.id) ||
      # Slow path: sender was CC'd/To'd in another thread conversation
      thread_conversations.detect { |c| sender_is_conversation_participant?(c) }
  end

  def create_new_conversation(originated_from: nil)
    conversation = ::Conversation.create!(
      account_id: @account.id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: {
        source: 'email',
        in_reply_to: in_reply_to,
        auto_reply: @processed_mail.auto_reply?,
        mail_subject: @processed_mail.subject,
        initiated_at: {
          timestamp: Time.now.utc
        }
      }
    )

    attach_origin_context(conversation, originated_from) if originated_from.present?

    conversation
  end

  def attach_origin_context(conversation, origin)
    # Activity message: visible cross-reference in the activity timeline
    conversation.messages.create!(
      message_type: :activity,
      content: "This conversation originated from conversation ##{origin.display_id}",
      content_attributes: { originated_from_conversation_id: origin.display_id },
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id
    )

    # Private note: include the original email content for agent context
    original_msg = origin.messages.incoming.order(:created_at).first
    return unless original_msg

    conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      content: "Original message from conversation ##{origin.display_id}:\n\n#{original_msg.content}".truncate(150_000),
      content_attributes: {
        originated_from_conversation_id: origin.display_id,
        email: original_msg.content_attributes['email']
      },
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: original_msg.sender
    )
  end

  # A sender is considered a participant if:
  # 1. They are the conversation's original contact (same person replying), OR
  # 2. Their email appeared in CC/To/From of any previous message (visible participant)
  def sender_is_conversation_participant?(conversation)
    return true if @contact.id == conversation.contact_id

    sender_email = @processed_mail.original_sender&.downcase
    return false if sender_email.blank?

    conversation_has_visible_participant?(conversation, sender_email)
  end

  def conversation_has_visible_participant?(conversation, email)
    sanitized = "%#{ActiveRecord::Base.sanitize_sql_like(email)}%"

    # content_attributes is a json column with double-encoded data (JSON string containing JSON).
    # Use #>>'{}' to extract the raw string, then ::jsonb to parse it as actual JSONB.
    conversation.messages.where(
      <<~SQL.squish, sanitized, sanitized, sanitized, sanitized, sanitized
        LOWER((content_attributes#>>'{}')::jsonb->>'to_emails') LIKE ?
        OR LOWER((content_attributes#>>'{}')::jsonb->>'cc_emails') LIKE ?
        OR LOWER((content_attributes#>>'{}')::jsonb->>'cc_email') LIKE ?
        OR LOWER((content_attributes#>>'{}')::jsonb->'email'->>'to') LIKE ?
        OR LOWER((content_attributes#>>'{}')::jsonb->'email'->>'from') LIKE ?
      SQL
    ).exists?
  end

  def find_or_create_contact
    @contact = @inbox.contacts.from_email(@processed_mail.original_sender)
    if @contact.present?
      @contact_inbox = ContactInbox.find_by(inbox: @inbox, contact: @contact)
    else
      create_contact
    end
  end

  def identify_contact_name
    processed_mail.sender_name || processed_mail.from.first.split('@').first
  end
end

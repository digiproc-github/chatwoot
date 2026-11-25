class Mailbox::ConversationFinder
  include MailboxSanitizer

  DEFAULT_STRATEGIES = [
    Mailbox::ConversationFinderStrategies::ReceiverUuidStrategy,
    Mailbox::ConversationFinderStrategies::InReplyToStrategy,
    Mailbox::ConversationFinderStrategies::ReferencesStrategy,
    Mailbox::ConversationFinderStrategies::NewConversationStrategy
  ].freeze

  def initialize(mail, strategies: DEFAULT_STRATEGIES)
    @mail = mail
    @strategies = strategies
  end

  def find
    @strategies.each do |strategy_class|
      conversation = strategy_class.new(@mail).find

      next unless conversation

      strategy_name = strategy_class.name.demodulize.underscore
      Rails.logger.info "Conversation found via #{strategy_name} strategy"
      return conversation if visible_sender?(conversation)

      return split_conversation(conversation)
    end

    # Should not reach here if NewConversationStrategy is in the chain
    Rails.logger.error 'No conversation found via any strategy (NewConversationStrategy missing?)'
    nil
  end

  private

  # A sender who was not visible on an email conversation (for example a BCC recipient) shares its thread headers
  # and reply address, but gets a conversation of their own, so agent replies go to them and not to the original contact.
  # Without a usable sender address there is nobody to split the email off to.
  def visible_sender?(conversation)
    return true unless conversation.inbox.email?
    return true unless Devise.email_regexp.match?(sender_email.to_s)

    Mailbox::ConversationParticipant.new(conversation, sender_email).participant?
  end

  def split_conversation(origin)
    Rails.logger.info "Sender was not visible on conversation #{origin.id}, using a separate conversation"
    Mailbox::ConversationFinderStrategies::NewConversationStrategy.new(@mail, split_from: origin).find
  end

  def sender_email
    @sender_email ||= sanitize_mailbox_value(MailPresenter.new(@mail).original_sender)&.downcase
  end
end

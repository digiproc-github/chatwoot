# Decides whether an email sender was visible on a conversation's emails.
# BCC recipients get the same thread headers as everyone else, but nobody else saw them on the email,
# so they are never participants.
class Mailbox::ConversationParticipant
  # Visible addresses in message content_attributes: incoming emails keep their parsed headers under `email`
  # and their CC list under `cc_email`; agent replies keep the To and CC recipients the agent entered.
  VISIBLE_ADDRESS_PATHS = [
    %w[email from],
    %w[email to],
    %w[email cc],
    %w[cc_email],
    %w[to_emails],
    %w[cc_emails]
  ].freeze

  def initialize(conversation, email)
    @conversation = conversation
    @email = email.to_s.downcase
  end

  def participant?
    return true if @conversation.contact.email&.downcase == @email

    visible_addresses.include?(@email)
  end

  private

  # Plucks only the address lists, so the stored email bodies are not loaded.
  def visible_addresses
    address_columns = VISIBLE_ADDRESS_PATHS.map { |path| address_list(path) }
    rows = @conversation.messages.where(message_type: %i[incoming outgoing], private: false).pluck(*address_columns)

    rows.flatten.grep(String).map(&:downcase)
  end

  def address_list(path)
    Arel::Nodes::InfixOperation.new('#>', content_attributes_jsonb, Arel::Nodes.build_quoted("{#{path.join(',')}}"))
  end

  # content_attributes is a json column that stores a JSON-encoded string,
  # so the string is unwrapped (#>> '{}') and cast to jsonb before reading paths from it.
  def content_attributes_jsonb
    json_text = Arel::Nodes::InfixOperation.new('#>>', Message.arel_table[:content_attributes], Arel::Nodes.build_quoted('{}'))
    Arel::Nodes::NamedFunction.new('CAST', [json_text.as('jsonb')])
  end
end

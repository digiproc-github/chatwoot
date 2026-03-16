class AddCachedLabelsList < ActiveRecord::Migration[7.0]
  def change
    add_column :conversations, :cached_label_list, :string
    Conversation.reset_column_information
    # ActsAsTaggableOn::Taggable::Cache was removed in acts-as-taggable-on v12
    # Safe to skip on fresh installs (no existing data to backfill)
    return unless defined?(ActsAsTaggableOn::Taggable::Cache)

    ActsAsTaggableOn::Taggable::Cache.included(Conversation)
  end
end

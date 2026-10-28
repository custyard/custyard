defmodule Custyard.ConversationLabel do
  use Ecto.Schema

  @primary_key false
  schema "conversation_labels" do
    belongs_to :tenant, Custyard.Tenant
    belongs_to :conversation, Custyard.Conversation, primary_key: true
    belongs_to :label, Custyard.Label, primary_key: true
    timestamps(type: :utc_datetime, updated_at: false)
  end
end

defmodule Custyard.Message do
  use Ecto.Schema
  import Ecto.Changeset

  # Message types: how the message was sent
  @sources [:email, :portal, :operator]

  # Origins: which adapter/integration the message came from (for audit/reporting)
  # Aligns with Conversation.@sources for consistent tracking
  @origins [:email, :lettermint, :zendesk, :intercom, :slack, :portal, :disambiguation]

  schema "messages" do
    field :source, Ecto.Enum, values: @sources
    # Origin tracks the original adapter source for audit/reporting
    # e.g., a message with source: :email might have origin: :lettermint
    field :origin, Ecto.Enum, values: @origins
    field :sender_email, :string
    field :body, :string
    field :is_internal_note, :boolean, default: false
    field :message_id, :string
    field :in_reply_to, :string

    belongs_to :conversation, Custyard.Conversation

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def sources, do: @sources
  def origins, do: @origins

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :source,
      :origin,
      :sender_email,
      :body,
      :is_internal_note,
      :message_id,
      :in_reply_to,
      :conversation_id
    ])
    |> validate_required([:source, :body, :conversation_id])
    |> validate_length(:body, max: 100_000)
    |> validate_inclusion(:source, @sources)
    |> maybe_validate_origin()
    |> foreign_key_constraint(:conversation_id)
  end

  defp maybe_validate_origin(changeset) do
    case get_field(changeset, :origin) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :origin, @origins)
    end
  end
end

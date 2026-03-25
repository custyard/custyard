defmodule Custyard.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @sources [:email, :portal, :operator]

  schema "messages" do
    field :source, Ecto.Enum, values: @sources
    field :sender_email, :string
    field :body, :string
    field :is_internal_note, :boolean, default: false
    field :message_id, :string
    field :in_reply_to, :string

    belongs_to :conversation, Custyard.Conversation

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def sources, do: @sources

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :source,
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
    |> foreign_key_constraint(:conversation_id)
  end
end

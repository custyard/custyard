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
    # Note: :source and :origin use Ecto.Enum which validates values automatically
    |> foreign_key_constraint(:conversation_id)
    # Unique constraint on message_id for webhook idempotency
    # Handle both possible index names (migration creates _unique_index, but SQLite
    # error messages sometimes report just _index due to how Exqlite parses errors)
    |> unique_constraint(:message_id, name: :messages_message_id_unique_index)
    |> unique_constraint(:message_id, name: :messages_message_id_index)
  end

  @doc """
  Insert a message, handling duplicate message_id gracefully.

  For webhook idempotency: if a message with the same message_id already exists,
  returns the existing message instead of creating a duplicate.

  Returns `{:ok, message}` on success or duplicate, `{:error, changeset}` on validation failure.
  """
  def insert_idempotent(attrs) do
    alias Custyard.Repo

    changeset = changeset(%__MODULE__{}, attrs)

    case Repo.insert(changeset) do
      {:ok, message} ->
        {:ok, message}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        # Check if it's a duplicate message_id error
        if Keyword.has_key?(errors, :message_id) and attrs[:message_id] do
          # Return the existing message
          case Repo.get_by(__MODULE__, message_id: attrs[:message_id]) do
            nil -> {:error, cs}
            existing -> {:ok, existing}
          end
        else
          {:error, cs}
        end
    end
  end
end

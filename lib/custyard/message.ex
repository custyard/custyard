defmodule Custyard.Message do
  use Ecto.Schema
  import Ecto.Changeset

  # Message types: how the message was sent
  # :prospect — anonymous public-intake submission or conversation-link reply
  @sources [:email, :portal, :operator, :prospect]

  # Origins: which adapter/integration the message came from (for audit/reporting)
  # Aligns with Conversation.@sources for consistent tracking
  @origins [
    :email,
    :lettermint,
    :zendesk,
    :intercom,
    :slack,
    :portal,
    :disambiguation,
    :public_intake
  ]

  # Delivery status for outbound messages (nil for inbound)
  # :withheld — recorded but deliberately not emailed (prospect reply channel
  # without reply-notification opt-in, or no recipient at all). Deliberately
  # distinct from the provider-side :suppressed failure state reserved for
  # the status webhook (issue #25): consent-withheld is an expected state,
  # provider-suppressed is a delivery failure.
  @delivery_statuses [:pending, :sent, :failed, :bounced, :withheld]

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
    field :lettermint_message_id, :string
    # Delivery status tracks outbound message lifecycle (nil for inbound messages)
    field :delivery_status, Ecto.Enum, values: @delivery_statuses

    # Soft delete (GitHub-style tombstone): the body stays in the database and
    # rendering surfaces show "This message was deleted" instead. There is no
    # hard-delete path. Set only via soft_delete_changeset/2.
    field :deleted_at, :utc_datetime
    belongs_to :deleted_by_operator, Custyard.OperatorAccount

    belongs_to :conversation, Custyard.Conversation

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources
  def origins, do: @origins
  def delivery_statuses, do: @delivery_statuses

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
      :lettermint_message_id,
      :delivery_status,
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
  Whether the message has been soft-deleted (tombstoned).
  """
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc """
  Changeset for soft-deleting a message (GitHub-style tombstone).

  Stamps `deleted_at` and the deleting operator. The body column is left
  untouched — the original content stays in the database and only rendering
  changes. Deliberately not part of `changeset/2` so external attrs can never
  set or clear the deletion fields.
  """
  def soft_delete_changeset(message, %Custyard.OperatorAccount{} = operator) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message
    |> change(deleted_at: now, deleted_by_operator_id: operator.id)
    |> foreign_key_constraint(:deleted_by_operator_id)
  end

  @doc """
  Changeset for updating delivery status on an existing outbound message.

  `extra_attrs` optionally carries `:lettermint_message_id` so the provider
  message id from a successful delivery can be recorded alongside the status.
  """
  def delivery_status_changeset(message, status, extra_attrs \\ %{}) do
    message
    |> cast(Map.put(extra_attrs, :delivery_status, status), [
      :delivery_status,
      :lettermint_message_id
    ])
    |> validate_required([:delivery_status])
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

defmodule Custyard.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Custyard.{Conversation, Repo}

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
  # :sending — claimed by a delivery attempt that has not reported back yet
  # (see Custyard.Email.Outbound.deliver/1); a row left in this state by a
  # crash is failed by the queue's recovery scan, never re-sent.
  # :delivered — the provider's status webhook reported acceptance by the
  # recipient's mail server (see Custyard.Email.DeliveryStatus).
  # :suppressed — the provider refused to send because the recipient is on a
  # suppression list; a delivery failure reported by the status webhook.
  # :withheld — recorded but deliberately not emailed (prospect reply channel
  # without reply-notification opt-in, or no recipient at all). Deliberately
  # distinct from provider-side :suppressed: consent-withheld is an expected
  # state, provider-suppressed is a delivery failure.
  #
  # Ranking (spec-conversation-loop, Delivery Tracking): pending < sending <
  # sent < delivered; bounced, suppressed and failed are terminal. A status
  # event only advances a message when its rank is higher or it is terminal.
  # :operator_sent — a reply the operator sent from their own mailbox, outside
  # Custyard, captured by triage (D6). :operator_forward — customer mail an
  # operator manually forwarded in; the message carries the original sender.
  @triage_classes [:customer, :auto_response, :suspect, :operator_sent, :operator_forward]

  @delivery_statuses [
    :pending,
    :sending,
    :sent,
    :delivered,
    :failed,
    :bounced,
    :suppressed,
    :withheld
  ]

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
    # Provider webhook delivery id (Lettermint's top-level `id`, reused on
    # retries). Second idempotency key for inbound deliveries, alongside
    # (tenant_id, message_id). nil for outbound messages.
    field :provider_delivery_id, :string
    # Delivery status tracks outbound message lifecycle (nil for inbound messages)
    field :delivery_status, Ecto.Enum, values: @delivery_statuses
    field :delivery_failure_kind, Ecto.Enum, values: [:rejected, :unknown, :configuration]
    field :delivery_error_code, :string
    field :delivery_attempted_at, :utc_datetime
    field :delivery_payload_hash, :string
    # New replies retain the recipient reviewed at enqueue. An empty locked
    # recipient list (for example after erasure) must never be repopulated.
    field :delivery_recipients_locked, :boolean, default: false

    # Email facts for inbound messages (spec-inbound-channels D5). Recipients
    # as bare addresses; CC'd parties are participants, not contacts.
    field :to_addresses, {:array, :string}, default: []
    field :cc_addresses, {:array, :string}, default: []
    field :reply_to, :string
    # Compact authentication summary: %{"dkim", "dkim_domain", "spf", "dmarc"}
    field :authentication, :map
    field :spam_score, :float
    # Triage class (D6): :customer, :auto_response (system message appended
    # to a thread), :suspect (spam-flagged or unauthenticated unknown sender).
    # nil for operator, portal and legacy rows.
    field :triage_class, Ecto.Enum, values: @triage_classes
    belongs_to :inbound_channel, Custyard.InboundChannel

    # Allowlist-sanitised HTML body (D9), stored alongside the text body.
    # nil when the mail was text-only or the HTML was too large to keep.
    field :html_body, :string
    # Manual-forward provenance (D6): the operator who forwarded a customer
    # thread in, and the operator-owned address it came from.
    belongs_to :forwarded_by_operator, Custyard.OperatorAccount
    field :forwarded_by_email, :string
    has_many :attachments, Custyard.MessageAttachment
    # Per-recipient delivery outcome (spec-conversation-loop, "Delivery Tracking")
    has_many :recipient_statuses, Custyard.MessageRecipientStatus

    # Soft delete (GitHub-style tombstone): the body stays in the database and
    # rendering surfaces show "This message was deleted" instead. There is no
    # hard-delete path. Set only via soft_delete_changeset/2.
    field :deleted_at, :utc_datetime
    belongs_to :deleted_by_operator, Custyard.OperatorAccount

    belongs_to :tenant, Custyard.Tenant
    belongs_to :conversation, Custyard.Conversation

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources
  def origins, do: @origins
  def delivery_statuses, do: @delivery_statuses
  def triage_classes, do: @triage_classes

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
      :tenant_id,
      :in_reply_to,
      :lettermint_message_id,
      :provider_delivery_id,
      :delivery_status,
      :to_addresses,
      :cc_addresses,
      :reply_to,
      :authentication,
      :spam_score,
      :triage_class,
      :inbound_channel_id,
      :html_body,
      :forwarded_by_operator_id,
      :forwarded_by_email,
      :conversation_id
    ])
    |> put_tenant_from_conversation()
    |> validate_required([:tenant_id, :source, :body, :conversation_id])
    |> validate_length(:body, max: 100_000)
    |> validate_length(:html_body, max: 500_000)
    |> validate_length(:forwarded_by_email, max: 255)
    |> validate_length(:provider_delivery_id, max: 255)
    |> validate_length(:reply_to, max: 255)
    |> validate_length(:to_addresses, max: 50)
    |> validate_length(:cc_addresses, max: 50)
    # Note: :source and :origin use Ecto.Enum which validates values automatically
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:inbound_channel_id)
    |> foreign_key_constraint(:forwarded_by_operator_id)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :message_id],
      name: :messages_tenant_id_message_id_index,
      error_key: :message_id
    )
    |> unique_constraint([:tenant_id, :provider_delivery_id],
      name: :messages_tenant_id_provider_delivery_id_index,
      error_key: :provider_delivery_id
    )
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
      :lettermint_message_id,
      :delivery_failure_kind,
      :delivery_error_code,
      :delivery_attempted_at,
      :delivery_payload_hash
    ])
    |> validate_required([:delivery_status])
  end

  @doc "Insert a message idempotently within its tenant."
  def insert_idempotent(attrs) do
    changeset = changeset(%__MODULE__{}, attrs)
    tenant_id = get_field(changeset, :tenant_id)

    case Repo.insert(changeset) do
      {:ok, message} -> {:ok, message}
      {:error, %Ecto.Changeset{} = cs} -> recover_duplicate(attrs, tenant_id, cs)
    end
  end

  defp recover_duplicate(attrs, tenant_id, %Ecto.Changeset{errors: errors} = cs) do
    existing =
      cond do
        Keyword.has_key?(errors, :provider_delivery_id) && attrs[:provider_delivery_id] ->
          Repo.get_by(__MODULE__,
            tenant_id: tenant_id,
            provider_delivery_id: attrs[:provider_delivery_id]
          )

        Keyword.has_key?(errors, :message_id) && attrs[:message_id] ->
          Repo.get_by(__MODULE__, tenant_id: tenant_id, message_id: attrs[:message_id])

        true ->
          nil
      end

    if existing, do: {:ok, existing}, else: {:error, cs}
  end

  # The parent thread supplies authoritative tenant ownership for all writers.
  # Explicit attributes remain subject to the composite database foreign key.
  defp put_tenant_from_conversation(changeset) do
    case get_field(changeset, :conversation_id) do
      id when is_integer(id) ->
        case Repo.get(Conversation, id) do
          %Conversation{tenant_id: tenant_id} ->
            case get_field(changeset, :tenant_id) do
              nil -> put_change(changeset, :tenant_id, tenant_id)
              ^tenant_id -> changeset
              _ -> add_error(changeset, :tenant_id, "does not match the parent thread")
            end

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end
end

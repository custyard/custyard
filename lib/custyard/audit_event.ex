defmodule Custyard.AuditEvent do
  @moduledoc """
  Schema for persisting audit events (webhook processing, operator actions
  such as slug release, operator accounts created or removed outside the UI,
  and acknowledgment replays and bindings).

  Records are queryable by conversation, organization, or message_id. New
  payloads use event-specific allowlists and internal IDs rather than duplicate
  addresses or correspondence. External acknowledgment identities and body
  digests remain exact evidence, with restricted access and separate retention.
  RFC Message-IDs are also retained for correlation; they can identify a
  mailbox and are subject to scoped contact erasure. The source column names
  an internal action channel or integration and is not a contact address.

  Events are append-only except for explicit contact-erasure redaction of
  legacy correspondence. That operation preserves event identity and time;
  a new erasure event records the affected event IDs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Custyard.AuditEvent.{LegacyRedaction, Payload}

  @event_types [
    :webhook_received,
    :webhook_processed,
    :webhook_error,
    :slug_released,
    :prospect_converted,
    :operator_created,
    :operator_removed,
    :operator_tenant_access_granted,
    :acknowledgment_replayed,
    :acknowledgment_binding_created,
    # Provider delivery-status webhook advanced an outbound message's status
    :delivery_status_updated,
    # Inbound channels (spec-inbound-channels D6/D7): admin actions and
    # lifecycle transitions, the quiet-channel notice, and triage outcomes
    # that did not become a customer message
    :channel_created,
    :channel_updated,
    :channel_deleted,
    :channel_state_changed,
    :channel_token_rotated,
    :channel_token_revealed,
    :channel_verification_captured,
    :channel_sending_domain_checked,
    :channel_quiet,
    :inbound_triaged,
    # Data subject request (spec-inbound-channels, Privacy): a participant
    # address was removed from message recipients. The payload never carries
    # the address itself.
    :data_subject_erasure
  ]

  # Fixed action channels and registered webhook adapters. External
  # acknowledgment source identities belong in their explicit payload schema.
  @sources ~w(email lettermint zendesk intercom slack portal webhook unknown operator boot cli mix console inbound_channels dsar test)

  schema "audit_events" do
    field :event_type, Ecto.Enum, values: @event_types
    field :source, :string
    field :message_id, :string
    field :payload, :map

    belongs_to :conversation, Custyard.Conversation
    belongs_to :organization, Custyard.Organization
    belongs_to :project, Custyard.Project

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def event_types, do: @event_types

  @doc false
  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [
      :event_type,
      :source,
      :message_id,
      :payload,
      :conversation_id,
      :organization_id,
      :project_id
    ])
    |> validate_required([:event_type, :source])
    |> validate_length(:source, max: 100)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:message_id, max: 500)
    |> minimize_payload()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Create and insert an audit event.

  Returns `{:ok, audit_event}` or `{:error, changeset}`.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Custyard.Repo.insert()
  end

  defp minimize_payload(changeset) do
    case get_change(changeset, :payload) do
      payload when is_map(payload) ->
        put_change(
          changeset,
          :payload,
          Payload.minimize(payload, get_field(changeset, :event_type))
        )

      _ ->
        changeset
    end
  end

  @doc """
  Redacts legacy customer data during an explicit contact-erasure transaction.
  Event identity, time and unrelated actor data remain intact. Matching
  mailbox identifiers in RFC Message-IDs are also replaced with [ERASED]. The caller
  records the returned IDs in its new data-subject-erasure audit event.
  """
  def redact_subject_data(email, organization_id, owned_conversation_ids),
    do: LegacyRedaction.redact(email, organization_id, owned_conversation_ids)
end

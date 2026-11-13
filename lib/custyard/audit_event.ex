defmodule Custyard.AuditEvent do
  @moduledoc """
  Schema for persisting audit events (webhook processing, staff actions
  such as thread state changes, ignoring a sender and slug release, staff
  accounts created or removed outside the UI, and acknowledgment replays and
  bindings).

  Records are queryable by thread, organization, or message_id. New
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

  @instance_events [:instance_admin_created, :instance_admin_removed, :installation_configured]

  @event_types @instance_events ++
                 [
                   :webhook_received,
                   :webhook_processed,
                   :webhook_error,
                   :slug_released,
                   :prospect_converted,
                   :staff_created,
                   :staff_removed,
                   :tenant_status_changed,
                   :tenant_host_removed,
                   :acknowledgment_replayed,
                   :acknowledgment_binding_created,
                   # Provider delivery-status webhook advanced an outbound message's status
                   :delivery_status_updated,
                   :reply_queued,
                   :internal_note_created,
                   :reply_retried,
                   :outbound_pause_changed,
                   # Staff actions on a thread: a state change (set state, dismiss)
                   # and ignoring or unignoring its sender
                   :thread_state_changed,
                   :sender_ignored,
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
  @sources ~w(email lettermint zendesk intercom slack portal webhook unknown staff instance_admin system acknowledgments lmtp cli mix console inbound_channels dsar test)

  schema "audit_events" do
    field :event_type, Ecto.Enum, values: @event_types
    field :source, :string
    field :message_id, :string
    field :payload, :map

    belongs_to :tenant, Custyard.Tenant
    belongs_to :thread, Custyard.Thread
    belongs_to :organization, Custyard.Organization
    belongs_to :project, Custyard.Project

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def event_types, do: @event_types

  @doc false
  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [
      :tenant_id,
      :event_type,
      :source,
      :message_id,
      :payload,
      :thread_id,
      :organization_id,
      :project_id
    ])
    |> put_resource_tenant()
    |> validate_required([:event_type, :source])
    |> require_tenant_for_workspace_event()
    |> validate_length(:source, max: 100)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:message_id, max: 500)
    |> minimize_payload()
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:project_id)
  end

  defp require_tenant_for_workspace_event(changeset) do
    if get_field(changeset, :event_type) in @instance_events,
      do: changeset,
      else: validate_required(changeset, [:tenant_id])
  end

  defp put_resource_tenant(changeset) do
    Enum.reduce(
      [
        thread_id: Custyard.Thread,
        organization_id: Custyard.Organization,
        project_id: Custyard.Project
      ],
      changeset,
      fn {field, schema}, cs ->
        case get_field(cs, field) do
          id when is_integer(id) ->
            case Custyard.Repo.get(schema, id) do
              %{tenant_id: tenant_id} ->
                case get_field(cs, :tenant_id) do
                  nil -> put_change(cs, :tenant_id, tenant_id)
                  ^tenant_id -> cs
                  _ -> add_error(cs, :tenant_id, "does not match the audited resource")
                end

              _ ->
                cs
            end

          _ ->
            cs
        end
      end
    )
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
  def redact_subject_data(email, organization_id, owned_thread_ids),
    do: LegacyRedaction.redact(email, organization_id, owned_thread_ids)
end

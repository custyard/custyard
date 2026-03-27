defmodule Custyard.AuditEvent do
  @moduledoc """
  Schema for persisting webhook audit events.

  Provides an append-only audit log for compliance and debugging.
  Records are queryable by conversation, organization, or message_id.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @event_types [:webhook_received, :webhook_processed, :webhook_error]

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
    |> validate_length(:message_id, max: 500)
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
end

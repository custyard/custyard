defmodule Custyard.EmailConnection do
  @moduledoc "Tenant-owned email connection. Provider secrets are encrypted and never rendered."
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_connections" do
    belongs_to :tenant, Custyard.Tenant
    belongs_to :default_channel, Custyard.InboundChannel
    belongs_to :latest_received_thread, Custyard.Thread
    field :project_id, :string
    field :project_token_ciphertext, :string, redact: true
    field :team_token_ciphertext, :string, redact: true
    field :status_webhook_id, :string
    field :status_secret_ciphertext, :string, redact: true
    field :status_callback_token, :string, redact: true
    field :project_checked_at, :utc_datetime
    field :project_check_status, :string, default: "unchecked"
    field :sending_checked_at, :utc_datetime
    field :sending_check_status, :string, default: "unchecked"
    field :last_signed_inbound_at, :utc_datetime
    field :last_returning_reply_at, :utc_datetime
    field :last_reply_accepted_at, :utc_datetime
    field :last_reply_delivered_at, :utc_datetime
    field :last_status_event_at, :utc_datetime
    field :reply_evidence_after_message_id, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:tenant_id, :project_id])
    |> validate_required([:tenant_id])
    |> validate_length(:project_id, max: 255)
    |> unique_constraint(:tenant_id)
    |> foreign_key_constraint(:tenant_id)
  end
end

defmodule Custyard.Repo.Migrations.CreateInboundChannels do
  use Ecto.Migration

  # One public support address bound to a Lettermint-backed inbound route
  # (docs/design/spec-inbound-channels.md, D1/D2/D7). A route carries many
  # channels; each channel is reached at `<local>+<token>@<route domain>`.
  def change do
    create table(:inbound_channels) do
      add :inbound_route_id, references(:inbound_routes, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :nilify_all)

      # The address customers write to (support@companyname.com), lowercased.
      add :public_address, :string, null: false
      # From display name for replies; nil falls back to the organization name.
      add :display_name, :string

      # Ingress address parts. The local part mirrors the public address for
      # operator readability; the token is 20 lowercase Crockford base32
      # characters (100 bits). A rotated token stays valid until
      # previous_token_expires_at so a forwarding rule can be updated first.
      add :ingress_local, :string, null: false
      add :ingress_token, :string, null: false
      add :previous_ingress_token, :string
      add :previous_token_expires_at, :utc_datetime

      # forward | mx | imap (D8); provider hint proton | google | other.
      add :ingress_kind, :string, null: false, default: "forward"
      add :provider, :string

      # draft | pending_verification | awaiting_first_message | active |
      # paused | revoked (D7)
      add :state, :string, null: false, default: "draft"

      # From identity for operator replies (D3): public_address, or
      # ingress_address as the fallback when the operator cannot verify the
      # root domain for sending.
      add :reply_from, :string, null: false, default: "public_address"
      # Lettermint sending-domain status for the public address domain, as
      # last checked: verified | partially_verified | pending_verification |
      # failed_verification | not_found. nil until checked.
      add :sending_domain_status, :string
      add :sending_domain_checked_at, :utc_datetime

      # Provider forwarding confirmation captured by triage (D6), 24h TTL.
      add :verification_code, :string
      add :verification_link, :string
      add :verification_captured_at, :utc_datetime
      add :verification_expires_at, :utc_datetime

      # Health (D7)
      add :verified_at, :utc_datetime
      add :last_received_at, :utc_datetime
      add :quiet_after_hours, :integer, null: false, default: 72
      add :quiet_notified_at, :utc_datetime
      add :paused_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:inbound_channels, [:ingress_token])

    create unique_index(:inbound_channels, [:previous_ingress_token],
             where: "previous_ingress_token IS NOT NULL"
           )

    create unique_index(:inbound_channels, [:inbound_route_id, :public_address])
    create index(:inbound_channels, [:organization_id])
    create index(:inbound_channels, [:state])
  end
end

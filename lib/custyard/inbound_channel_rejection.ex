defmodule Custyard.InboundChannelRejection do
  @moduledoc """
  A delivery that reached a route but did not become a customer message.

  Written by the triage stage (spec-inbound-channels D6) so an operator can
  answer "did my customer's mail get lost?". Holds the sender, recipient,
  subject and classification only; the body is never stored. Rows are swept
  after 14 days by `Custyard.InboundChannels.sweep_expired/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @classifications [
    # recipient matched no channel on the route
    :no_channel,
    # channel paused, or token revoked
    :channel_paused,
    :channel_revoked,
    # auto-response or bulk mail that threaded to nothing
    :auto_response,
    # provider forwarding notification outside a pending verification
    :provider_notice,
    # Custyard's own outbound reply forwarded back (D4 echo)
    :own_echo,
    # IMAP channel (D8): a message over the import size cap, or one the
    # MIME parser could not read; the poller moves past both
    :too_large,
    :unreadable
  ]

  schema "inbound_channel_rejections" do
    field :tenant_id, :id, default: 1
    belongs_to :tenant, Custyard.Tenant, define_field: false
    field :sender_email, :string
    field :recipient, :string
    field :subject, :string
    field :classification, Ecto.Enum, values: @classifications
    field :provider_delivery_id, :string

    belongs_to :inbound_route, Custyard.InboundRoute
    belongs_to :inbound_channel, Custyard.InboundChannel
    belongs_to :organization, Custyard.Organization

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def classifications, do: @classifications

  @doc false
  def changeset(rejection, attrs) do
    rejection
    |> cast(attrs, [
      :sender_email,
      :recipient,
      :subject,
      :classification,
      :provider_delivery_id,
      :inbound_route_id,
      :inbound_channel_id,
      :organization_id,
      :tenant_id
    ])
    |> validate_required([:classification, :inbound_route_id, :tenant_id])
    |> validate_length(:sender_email, max: 255)
    |> validate_length(:recipient, max: 255)
    |> validate_length(:subject, max: 500)
    |> validate_length(:provider_delivery_id, max: 255)
    |> foreign_key_constraint(:inbound_route_id)
    |> foreign_key_constraint(:inbound_channel_id)
    |> foreign_key_constraint(:organization_id)
  end
end

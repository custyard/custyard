defmodule Custyard.InboundRouteWebhook do
  @moduledoc """
  Represents a webhook consumer registered on an inbound route.

  Each route can have multiple webhooks with different purposes:
  - `:sender_matching` — identity resolution, conversation creation
  - `:enrichment` — urgency scoring, keyword extraction
  - `:notification` — operator notifications (Slack, push, email)
  - `:audit` — append-only activity log
  - `:disambiguation` — sends disambiguation DM to ambiguous sender
  """
  use Ecto.Schema
  import Ecto.Changeset

  @purposes [:sender_matching, :enrichment, :notification, :audit, :disambiguation]

  schema "inbound_route_webhooks" do
    field :lettermint_webhook_id, :string
    field :endpoint_url, :string
    field :purpose, Ecto.Enum, values: @purposes
    field :enabled, :boolean, default: true

    belongs_to :inbound_route, Custyard.InboundRoute

    timestamps(type: :utc_datetime)
  end

  def purposes, do: @purposes

  @doc false
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [
      :lettermint_webhook_id,
      :endpoint_url,
      :purpose,
      :enabled,
      :inbound_route_id
    ])
    |> validate_required([:purpose, :inbound_route_id])
    |> validate_inclusion(:purpose, @purposes)
    |> unique_constraint([:inbound_route_id, :purpose])
    |> foreign_key_constraint(:inbound_route_id)
  end
end

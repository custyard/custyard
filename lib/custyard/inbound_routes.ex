defmodule Custyard.InboundRoutes do
  @moduledoc """
  Context for managing inbound routes.

  Routes are invisible infrastructure — operators never interact with them
  directly. Route lifecycle is tied to organization and project lifecycle:
  creating an org auto-provisions a general route via the Lettermint API,
  and deleting an org cascades to its routes.
  """

  alias Custyard.{InboundRoute, InboundRouteWebhook, Organization, Repo}
  alias Custyard.Lettermint.Client
  import Ecto.Query

  @doc """
  Create an inbound route for an organization.

  Calls the Lettermint API to create the remote route, then stores
  the local record with the returned `lettermint_route_id`.

  ## Options

    * `:project_id` - required for `:project` route type

  ## Examples

      create_route(org, :general)
      create_route(org, :project, project_id: project.id)

  """
  def create_route(%Organization{} = org, type, opts \\ []) do
    lettermint_client = Client.client()

    with {:ok, remote} <- lettermint_client.create_route(%{organization_id: org.id, type: type}) do
      attrs =
        %{
          organization_id: org.id,
          route_type: type,
          lettermint_route_id: remote["id"]
        }
        |> maybe_put(:project_id, Keyword.get(opts, :project_id))

      %InboundRoute{}
      |> InboundRoute.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  List all inbound routes for an organization, with webhooks preloaded.
  """
  def list_routes(%Organization{} = org) do
    from(r in InboundRoute,
      where: r.organization_id == ^org.id,
      preload: :webhooks,
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Get an inbound route by ID, raising if not found. Preloads webhooks.
  """
  def get_route!(id) do
    Repo.get!(InboundRoute, id) |> Repo.preload(:webhooks)
  end

  @doc """
  Delete an inbound route.

  Calls the Lettermint API to remove the remote route (if a
  `lettermint_route_id` is present), then deletes the local record.
  Webhooks cascade-delete via the DB foreign key.
  """
  def delete_route(%InboundRoute{} = route) do
    if route.lettermint_route_id do
      lettermint_client = Client.client()
      lettermint_client.delete_route(route.lettermint_route_id)
    end

    Repo.delete(route)
  end

  @doc """
  Enable a webhook purpose on a route.

  If a webhook record already exists for this purpose, sets `enabled: true`.
  If none exists, creates a new one.
  """
  def enable_webhook(%InboundRoute{} = route, purpose) do
    case get_webhook(route, purpose) do
      nil ->
        %InboundRouteWebhook{}
        |> InboundRouteWebhook.changeset(%{
          inbound_route_id: route.id,
          purpose: purpose,
          enabled: true
        })
        |> Repo.insert()

      webhook ->
        webhook
        |> InboundRouteWebhook.changeset(%{enabled: true})
        |> Repo.update()
    end
  end

  @doc """
  Disable a webhook purpose on a route.

  Returns `{:error, :not_found}` if no webhook exists for this purpose.
  """
  def disable_webhook(%InboundRoute{} = route, purpose) do
    case get_webhook(route, purpose) do
      nil ->
        {:error, :not_found}

      webhook ->
        webhook
        |> InboundRouteWebhook.changeset(%{enabled: false})
        |> Repo.update()
    end
  end

  @doc """
  Generate the full callback URL for a route.
  """
  def callback_url(%InboundRoute{} = route) do
    "#{CustyardWeb.Endpoint.url()}/api/webhook/route/#{route.callback_token}?source=lettermint"
  end

  # Private helpers

  defp get_webhook(%InboundRoute{} = route, purpose) do
    Repo.get_by(InboundRouteWebhook,
      inbound_route_id: route.id,
      purpose: purpose
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

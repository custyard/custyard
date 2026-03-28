defmodule Custyard.InboundRoutes do
  @moduledoc """
  Context for inbound route management.

  Routes are invisible infrastructure — operators never interact with them
  directly. Route lifecycle is tied to organization and project lifecycle:
  creating an org auto-provisions a general route via the Lettermint API,
  and deleting an org cascades to its routes.

  Provides CRUD operations for InboundRoute and InboundRouteWebhook,
  following the context pattern used elsewhere in the application.
  """

  require Logger

  alias Custyard.{InboundRoute, InboundRouteWebhook, Repo}
  alias Custyard.Lettermint.Client
  import Ecto.Query

  # --- InboundRoute Operations ---

  @doc """
  List all inbound routes for an organization.
  Preloads webhooks and project associations.
  """
  def list_for_organization(organization_id) when is_integer(organization_id) do
    from(r in InboundRoute,
      where: r.organization_id == ^organization_id,
      order_by: [asc: r.route_type, asc: r.inserted_at],
      preload: [:webhooks, :project]
    )
    |> Repo.all()
  end

  @doc """
  Get a single inbound route by ID.
  Preloads webhooks, organization, and project.
  Returns nil if not found.
  """
  def get_route(id) when is_integer(id) do
    InboundRoute
    |> Repo.get(id)
    |> Repo.preload([:webhooks, :organization, :project])
  end

  @doc """
  Get a single inbound route by ID, raising if not found.
  Preloads webhooks, organization, and project.
  """
  def get_route!(id) when is_integer(id) do
    InboundRoute
    |> Repo.get!(id)
    |> Repo.preload([:webhooks, :organization, :project])
  end

  @doc """
  Get an inbound route by its callback_token.
  Used for routing incoming webhook requests.
  Preloads webhooks and organization.
  Returns nil if not found.
  """
  def get_by_callback_token(token) when is_binary(token) do
    from(r in InboundRoute,
      where: r.callback_token == ^token,
      preload: [:webhooks, :organization, :project]
    )
    |> Repo.one()
  end

  @doc """
  Create a new inbound route.

  Calls the Lettermint API to create the remote route, then stores
  the local record with the returned `lettermint_route_id`.

  ## Examples

      create_route(%{
        organization_id: 1,
        route_type: :general
      })

      create_route(%{
        organization_id: 1,
        route_type: :project,
        project_id: 5
      })
  """
  def create_route(attrs) when is_map(attrs) do
    lettermint_client = Client.client()

    with {:ok, remote} <-
           lettermint_client.create_route(%{
             organization_id: attrs[:organization_id] || attrs["organization_id"],
             type: attrs[:route_type] || attrs["route_type"]
           }) do
      attrs_with_lettermint = Map.put(attrs, :lettermint_route_id, remote["id"])

      %InboundRoute{}
      |> InboundRoute.changeset(attrs_with_lettermint)
      |> Repo.insert()
    end
  end

  @doc """
  Update an inbound route.
  """
  def update_route(%InboundRoute{} = route, attrs) when is_map(attrs) do
    route
    |> InboundRoute.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete an inbound route.

  Calls the Lettermint API to remove the remote route (if a
  `lettermint_route_id` is present), then deletes the local record.
  Associated webhooks are deleted via database cascade.
  """
  def delete_route(%InboundRoute{} = route) do
    if route.lettermint_route_id do
      case Client.client().delete_route(route.lettermint_route_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to delete Lettermint route #{route.lettermint_route_id}: #{inspect(reason)}"
          )
      end
    end

    Repo.delete(route)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking route changes.
  Useful for form rendering in LiveView.
  """
  def change_route(%InboundRoute{} = route, attrs \\ %{}) do
    InboundRoute.changeset(route, attrs)
  end

  @doc """
  Generate the full callback URL for a route.
  """
  def callback_url(%InboundRoute{} = route) do
    "#{CustyardWeb.Endpoint.url()}/api/webhook/route/#{route.callback_token}?source=lettermint"
  end

  # --- InboundRouteWebhook Operations ---

  @doc """
  List all webhooks for an inbound route.
  """
  def list_webhooks_for_route(route_id) when is_integer(route_id) do
    from(w in InboundRouteWebhook,
      where: w.inbound_route_id == ^route_id,
      order_by: [asc: w.purpose]
    )
    |> Repo.all()
  end

  @doc """
  Get a single webhook by ID.
  Returns nil if not found.
  """
  def get_webhook(id) when is_integer(id) do
    Repo.get(InboundRouteWebhook, id)
  end

  @doc """
  Get a single webhook by ID, raising if not found.
  """
  def get_webhook!(id) when is_integer(id) do
    Repo.get!(InboundRouteWebhook, id)
  end

  @doc """
  Create a new webhook for an inbound route.

  ## Examples

      create_webhook(%{
        inbound_route_id: 1,
        purpose: :sender_matching,
        endpoint_url: "https://example.com/webhook"
      })
  """
  def create_webhook(attrs) when is_map(attrs) do
    %InboundRouteWebhook{}
    |> InboundRouteWebhook.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a webhook.
  """
  def update_webhook(%InboundRouteWebhook{} = webhook, attrs) when is_map(attrs) do
    webhook
    |> InboundRouteWebhook.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a webhook.
  """
  def delete_webhook(%InboundRouteWebhook{} = webhook) do
    Repo.delete(webhook)
  end

  @doc """
  Enable a webhook by struct.
  """
  def enable_webhook(%InboundRouteWebhook{} = webhook) do
    update_webhook(webhook, %{enabled: true})
  end

  @doc """
  Enable a webhook purpose on a route.

  If a webhook record already exists for this purpose, sets `enabled: true`.
  If none exists, creates a new one.
  """
  def enable_webhook(%InboundRoute{} = route, purpose) do
    case get_webhook_by_purpose(route, purpose) do
      nil ->
        create_webhook(%{
          inbound_route_id: route.id,
          purpose: purpose,
          enabled: true
        })

      webhook ->
        enable_webhook(webhook)
    end
  end

  @doc """
  Disable a webhook by struct.
  """
  def disable_webhook(%InboundRouteWebhook{} = webhook) do
    update_webhook(webhook, %{enabled: false})
  end

  @doc """
  Disable a webhook purpose on a route.

  Returns `{:error, :not_found}` if no webhook exists for this purpose.
  """
  def disable_webhook(%InboundRoute{} = route, purpose) do
    case get_webhook_by_purpose(route, purpose) do
      nil ->
        {:error, :not_found}

      webhook ->
        disable_webhook(webhook)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking webhook changes.
  Useful for form rendering in LiveView.
  """
  def change_webhook(%InboundRouteWebhook{} = webhook, attrs \\ %{}) do
    InboundRouteWebhook.changeset(webhook, attrs)
  end

  # --- Convenience Functions ---

  @doc """
  Find or create the general (catch-all) route for an organization.
  Returns {:ok, route} or {:error, changeset}.
  """
  def find_or_create_general_route(organization_id) when is_integer(organization_id) do
    case get_general_route(organization_id) do
      nil ->
        create_route(%{
          organization_id: organization_id,
          route_type: :general
        })

      route ->
        {:ok, route}
    end
  end

  @doc """
  Get the general (catch-all) route for an organization.
  Returns nil if not found.
  """
  def get_general_route(organization_id) when is_integer(organization_id) do
    from(r in InboundRoute,
      where: r.organization_id == ^organization_id and r.route_type == :general,
      preload: [:webhooks]
    )
    |> Repo.one()
  end

  @doc """
  Get the project-specific route for a project.
  Returns nil if not found.
  """
  def get_project_route(project_id) when is_integer(project_id) do
    from(r in InboundRoute,
      where: r.project_id == ^project_id and r.route_type == :project,
      preload: [:webhooks]
    )
    |> Repo.one()
  end

  # --- Private Helpers ---

  defp get_webhook_by_purpose(%InboundRoute{} = route, purpose) do
    Repo.get_by(InboundRouteWebhook,
      inbound_route_id: route.id,
      purpose: purpose
    )
  end
end

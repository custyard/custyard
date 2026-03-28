defmodule Custyard.Organizations do
  @moduledoc """
  Context for organization operations including custom domain management.
  """

  require Logger
  alias Custyard.{Contact, Conversation, InboundRoutes, Organization, Repo}
  import Ecto.Query

  @doc """
  Verify that a custom domain has proper DNS configuration.

  Checks that the domain has a CNAME record pointing to the app host.

  Returns:
  - `{:ok, :verified}` if DNS is correctly configured
  - `{:error, :no_cname}` if no CNAME record found
  - `{:error, :wrong_target}` if CNAME points to wrong host
  - `{:error, :dns_lookup_failed}` if DNS lookup failed
  """
  @spec verify_custom_domain(String.t()) ::
          {:ok, :verified}
          | {:error, :no_cname | :wrong_target | :dns_lookup_failed}
  def verify_custom_domain(domain) when is_binary(domain) do
    expected_host = get_app_host()

    case lookup_cname(domain) do
      {:ok, cname_target} ->
        # Normalize the CNAME target (remove trailing dot if present)
        normalized_target = String.trim_trailing(cname_target, ".")

        if String.downcase(normalized_target) == String.downcase(expected_host) do
          {:ok, :verified}
        else
          {:error, :wrong_target}
        end

      {:error, :no_cname} ->
        {:error, :no_cname}

      {:error, _reason} ->
        {:error, :dns_lookup_failed}
    end
  end

  @doc """
  Get the expected CNAME target for custom domains.
  """
  def expected_cname_target do
    get_app_host()
  end

  # Look up CNAME record using :inet_res
  defp lookup_cname(domain) do
    # Convert to charlist for :inet_res
    domain_charlist = String.to_charlist(domain)

    case :inet_res.lookup(domain_charlist, :in, :cname) do
      [] ->
        # No CNAME record found
        {:error, :no_cname}

      [cname_target | _] ->
        {:ok, List.to_string(cname_target)}
    end
  rescue
    _ ->
      {:error, :dns_lookup_failed}
  catch
    :exit, _ ->
      {:error, :dns_lookup_failed}
  end

  defp get_app_host do
    config = Application.get_env(:custyard, CustyardWeb.Endpoint, [])
    get_in(config, [:url, :host]) || "localhost"
  end

  @doc """
  Get an organization by ID.
  """
  def get_organization(id) do
    Repo.get(Organization, id)
  end

  @doc """
  Get an organization by ID, raising if not found.
  """
  def get_organization!(id) do
    Repo.get!(Organization, id)
  end

  @doc """
  Get an organization by ID with preloaded contacts.
  """
  def get_organization_with_contacts(id) do
    from(o in Organization,
      where: o.id == ^id,
      preload: [:contacts]
    )
    |> Repo.one()
  end

  @doc """
  List contacts for an organization.
  """
  def list_contacts(org_id) do
    from(c in Contact,
      where: c.organization_id == ^org_id,
      order_by: [asc: c.name, asc: c.email]
    )
    |> Repo.all()
  end

  @doc """
  Get an organization by token.
  """
  def get_organization_by_token(token) do
    Repo.get_by(Organization, token: token)
  end

  @doc """
  List all organizations.
  """
  def list_organizations do
    from(o in Organization, order_by: [asc: o.name])
    |> Repo.all()
  end

  @doc """
  List all organizations with conversation counts.
  """
  def list_organizations_with_counts do
    from(o in Organization,
      left_join: c in assoc(o, :conversations),
      group_by: o.id,
      select: %{org: o, conversation_count: count(c.id)},
      order_by: [asc: o.name]
    )
    |> Repo.all()
  end

  @doc """
  Create a new organization.
  """
  def create_organization(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, Organization.changeset(%Organization{}, attrs))
    |> Ecto.Multi.run(:default_route, fn _repo, %{organization: org} ->
      InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: org}} -> {:ok, org}
      {:error, :organization, changeset, _changes} -> {:error, changeset}
      {:error, :default_route, error, _changes} -> {:error, error}
    end
  end

  @doc """
  Update an organization.
  """
  def update_organization(%Organization{} = org, attrs) do
    org
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Build a changeset for an organization.
  """
  def change_organization(%Organization{} = org, attrs \\ %{}) do
    Organization.changeset(org, attrs)
  end

  @doc """
  Delete an organization.

  WARNING: This is a hard delete that cascades to all associated contacts and
  conversations. This action is irreversible. Deletion is logged for audit purposes.

  Returns `{:ok, organization}` or `{:error, changeset}`.
  """
  def delete_organization(%Organization{} = org) do
    # Count associated records for audit logging
    contact_count =
      Repo.aggregate(from(c in Contact, where: c.organization_id == ^org.id), :count)

    conversation_count =
      Repo.aggregate(from(c in Conversation, where: c.organization_id == ^org.id), :count)

    # Log deletion details before executing
    Logger.warning(
      "Deleting organization",
      organization_id: org.id,
      organization_name: org.name,
      organization_domain: org.domain,
      contacts_to_delete: contact_count,
      conversations_to_delete: conversation_count
    )

    result = Repo.delete(org)

    case result do
      {:ok, deleted} ->
        Logger.info(
          "Organization deleted successfully",
          organization_id: deleted.id,
          organization_name: deleted.name
        )

        # Emit telemetry for monitoring
        :telemetry.execute(
          [:custyard, :organization, :deleted],
          %{count: 1, contacts: contact_count, conversations: conversation_count},
          %{organization_id: org.id, organization_name: org.name}
        )

        {:ok, deleted}

      {:error, _} = error ->
        Logger.error("Failed to delete organization", organization_id: org.id)
        error
    end
  end

  @doc """
  Get an organization by custom domain.
  """
  def get_organization_by_custom_domain(domain) when is_binary(domain) do
    Repo.get_by(Organization, custom_domain: domain)
  end

  @doc """
  Regenerate the portal access token for an organization.

  This invalidates any existing portal links using the old token.
  Returns `{:ok, organization}` or `{:error, changeset}`.
  """
  def regenerate_portal_token(%Organization{} = org) do
    new_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    org
    |> Ecto.Changeset.change(token: new_token)
    |> Repo.update()
  end
end

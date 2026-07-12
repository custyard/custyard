defmodule Custyard.Organizations do
  @moduledoc """
  Context for organization operations including custom domain management.
  """

  require Logger

  alias Custyard.{
    AuditEvent,
    Contact,
    Conversation,
    Conversations,
    InboundRoutes,
    Organization,
    OperatorAccount,
    Prospect,
    Repo,
    Scoring,
    Slugs
  }

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

  Creates the organization in the database, then provisions a default inbound
  route via the Lettermint API. If route provisioning fails, the organization
  is deleted (compensating transaction pattern).

  Returns `{:ok, organization}` or `{:error, changeset}`.
  """
  def create_organization(attrs) do
    changeset = Organization.changeset(%Organization{}, attrs)

    case Repo.insert(changeset) do
      {:ok, org} ->
        maybe_provision_route(org, changeset)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_provision_route(%Organization{lettermint_project_id: nil} = org, _changeset) do
    {:ok, org}
  end

  defp maybe_provision_route(org, changeset) do
    case InboundRoutes.create_route(%{organization_id: org.id, route_type: :general}) do
      {:ok, _route} ->
        {:ok, org}

      {:error, reason} ->
        Repo.delete(org)
        {:error, wrap_route_error(changeset, reason)}
    end
  end

  # Wrap non-changeset errors into a changeset with a :base error for consistent return types
  defp wrap_route_error(changeset, {:api_error, message}) when is_binary(message) do
    Ecto.Changeset.add_error(changeset, :base, "Route provisioning failed: #{message}")
  end

  defp wrap_route_error(changeset, {:api_error, reason}) do
    Ecto.Changeset.add_error(changeset, :base, "Route provisioning failed: #{inspect(reason)}")
  end

  defp wrap_route_error(changeset, %Ecto.Changeset{} = error_changeset) do
    # If the route creation returned a changeset error, merge errors into base
    errors = Ecto.Changeset.traverse_errors(error_changeset, fn {msg, _opts} -> msg end)
    Ecto.Changeset.add_error(changeset, :base, "Route provisioning failed: #{inspect(errors)}")
  end

  defp wrap_route_error(changeset, reason) do
    Ecto.Changeset.add_error(changeset, :base, "Route provisioning failed: #{inspect(reason)}")
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

  @doc """
  Convert an unlinked public-intake conversation into a brand-new
  organization. Caller-gated: mirrors `create_organization/1`, which enforces
  no role check of its own — the LiveView checks
  `Authorization.can_create_organization?/1` before calling this. `operator`
  is recorded on the `:prospect_converted` audit event, not used for
  authorization.

  Step 1: `create_organization/1` unchanged — a Lettermint provisioning
  failure already compensates by deleting the org before this function ever
  sees it.

  Step 2, one transaction: the prospect is read inside the transaction (not
  before it), narrowing — though not eliminating, under READ COMMITTED — the
  window in which a concurrently committed email capture is missed (the
  conditional link below, `WHERE ... organization_id IS NULL`, is what makes
  this safe, not the read placement); race-safe conditional promotion of the
  conversation's confirmed slug claim
  (`Slugs.promote/2` — `{:error, :not_found}` is not a failure, a prospect
  can convert without ever having claimed a slug), a contact created from
  the prospect's captured email when present, then a conditional link
  (`WHERE id AND organization_id IS NULL`) so a conversation converted by a
  concurrent call is never silently re-linked. `source` stays
  `:public_intake` as provenance.

  Any step-2 failure — the conditional link losing its race, or a real
  error — compensates by deleting the organization: it is conversation-free
  until this transaction commits, so the delete is cascade-safe.

  Post-commit: rescore, `"conversations"` + org-scoped broadcasts, a
  `:prospect_converted` audit event. Resume access is untouched — conversion
  neither revokes nor rotates the prospect's resume token.

  Returns `{:ok, conversation}`, `{:error, :not_convertible}` (already
  linked, or not a public-intake conversation), `{:error, :already_converted}`
  (lost the race to a concurrent conversion), or `{:error, changeset}`.
  """
  def convert_prospect(
        %Conversation{organization_id: nil, source: :public_intake} = conversation,
        org_attrs,
        %OperatorAccount{} = operator
      ) do
    case create_organization(org_attrs) do
      {:ok, organization} ->
        conversation
        |> do_convert(organization)
        |> handle_convert_result(organization, operator)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def convert_prospect(%Conversation{}, _org_attrs, %OperatorAccount{}),
    do: {:error, :not_convertible}

  defp do_convert(conversation, organization) do
    Repo.transaction(fn ->
      prospect = Repo.get_by(Prospect, conversation_id: conversation.id)

      case Slugs.promote(conversation, organization) do
        {:ok, _slug} -> :ok
        {:error, :not_found} -> :ok
      end

      contact = maybe_create_contact(prospect, organization)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      set = [organization_id: organization.id, updated_at: now] |> maybe_put_contact(contact)

      {count, _} =
        Repo.update_all(
          from(c in Conversation, where: c.id == ^conversation.id and is_nil(c.organization_id)),
          set: set
        )

      case count do
        1 ->
          Repo.get!(Conversation, conversation.id) |> Repo.preload([:organization, :contact])

        0 ->
          Repo.rollback(:already_converted)
      end
    end)
  end

  defp maybe_create_contact(%Prospect{email: email}, organization) when is_binary(email) do
    case %Contact{}
         |> Contact.changeset(%{email: email, organization_id: organization.id})
         |> Repo.insert() do
      {:ok, contact} -> contact
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp maybe_create_contact(_prospect, _organization), do: nil

  defp maybe_put_contact(set, nil), do: set
  defp maybe_put_contact(set, %Contact{id: id}), do: Keyword.put(set, :contact_id, id)

  defp handle_convert_result({:ok, conversation}, organization, operator) do
    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    Conversations.broadcast_to_org(
      conversation.organization_id,
      {:conversation_updated, conversation.id}
    )

    record_conversion_audit(conversation, organization, operator)

    {:ok, conversation}
  end

  defp handle_convert_result({:error, reason}, organization, _operator) do
    delete_organization(organization)
    {:error, reason}
  end

  # Append-only audit trail for the conversion (AuditEvent.create pattern,
  # same as the slug-release audit write, including operator attribution).
  # A logging failure never blocks the conversion — it already committed.
  # organization_id is deliberately omitted from the payload: it is already
  # the row's schema column.
  defp record_conversion_audit(conversation, organization, operator) do
    case AuditEvent.create(%{
           event_type: :prospect_converted,
           source: "operator",
           payload: %{
             "organization_name" => organization.name,
             "operator_id" => operator.id,
             "operator_email" => operator.email
           },
           conversation_id: conversation.id,
           organization_id: organization.id
         }) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Failed to record prospect conversion audit event: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end
end

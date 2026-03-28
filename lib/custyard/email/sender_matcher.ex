defmodule Custyard.Email.SenderMatcher do
  @moduledoc """
  Match email sender to Contact/Organization.

  Supports two matching modes:
  1. `match/1` — domain-based matching (legacy, for unrouted webhooks)
  2. `match_within_org/2` — route-context matching (preferred, uses org from inbound route)

  Priority order for routing:
  1. Route context (org/project from inbound route)
  2. Contact match within route's org scope
  3. Global contact match (catchall only — handles multi-org disambiguation)
  4. Domain match (catchall, unknown sender)
  """

  require Logger
  alias Custyard.{Contact, Organization, Repo}
  import Ecto.Query

  def match(from_address) do
    email = extract_email(from_address)
    domain = extract_domain(email)

    case find_contacts_by_email(email) do
      [] ->
        # No contact found — try domain match or create unmatched
        match_by_domain_or_create(email, domain, from_address)

      [contact] ->
        # Single match — unambiguous
        org = Repo.get!(Organization, contact.organization_id)
        {:ok, org, contact}

      [contact | rest] ->
        # Multiple contacts across orgs — use the oldest contact (first relationship).
        # Route-context matching (match_within_org/2) is the preferred path
        # to avoid this ambiguity. Disambiguation DM flow handles this in
        # the catchall route via the disambiguation webhook purpose.
        org = Repo.get!(Organization, contact.organization_id)

        # Log warning for visibility into multi-org routing decisions
        other_org_ids = Enum.map(rest, & &1.organization_id)

        Logger.warning(
          "Multi-org sender ambiguity: email #{email} exists in #{length(rest) + 1} organizations. " <>
            "Routing to org #{org.id} (#{org.name}). Other org IDs: #{inspect(other_org_ids)}. " <>
            "Consider using route-context matching to avoid ambiguity."
        )

        {:ok, org, contact}
    end
  end

  @doc """
  Match a sender within a specific organization (route-context matching).

  The organization is already known from the inbound route. We only need
  to find or create the contact within that org scope.
  """
  def match_within_org(from_address, org_id) do
    email = extract_email(from_address)
    org = Repo.get!(Organization, org_id)

    case find_contact_in_org(email, org_id) do
      {:ok, contact} ->
        {:ok, org, contact}

      :not_found ->
        with {:ok, contact} <- create_contact(org, email, from_address) do
          {:ok, org, contact}
        end
    end
  end

  defp extract_email(from) do
    # Handle "Name <email>" format
    case Regex.run(~r/<([^>]+)>/, from) do
      [_, email] -> String.downcase(email)
      nil -> String.downcase(String.trim(from))
    end
  end

  defp extract_domain(email) do
    case String.split(email, "@") do
      [_, domain] -> domain
      _ -> nil
    end
  end

  defp find_contacts_by_email(email) do
    # Order by inserted_at to ensure deterministic behavior when the same email
    # exists in multiple organizations. Oldest contact (first relationship) wins.
    # This is a fallback for when route-context matching isn't available.
    from(c in Contact, where: c.email == ^email, order_by: [asc: c.inserted_at])
    |> Repo.all()
  end

  defp find_contact_in_org(email, org_id) do
    query =
      from c in Contact,
        where: c.email == ^email and c.organization_id == ^org_id

    case Repo.one(query) do
      nil -> :not_found
      contact -> {:ok, contact}
    end
  end

  defp match_by_domain_or_create(email, domain, from_address) do
    case find_org_by_domain(domain) do
      {:ok, org} ->
        with {:ok, contact} <- create_contact(org, email, from_address) do
          {:ok, org, contact}
        end

      :not_found ->
        with {:ok, org} <- get_or_create_unmatched_org(),
             {:ok, contact} <- create_contact(org, email, from_address) do
          {:ok, org, contact}
        end
    end
  end

  defp find_org_by_domain(nil), do: :not_found

  defp find_org_by_domain(domain) do
    case Repo.get_by(Organization, domain: domain) do
      nil -> :not_found
      org -> {:ok, org}
    end
  end

  defp create_contact(org, email, from) do
    name = extract_name(from)

    %Contact{}
    |> Contact.changeset(%{
      organization_id: org.id,
      email: email,
      name: name
    })
    |> Repo.insert()
  end

  defp extract_name(from) do
    case Regex.run(~r/^([^<]+)</, from) do
      [_, name] -> String.trim(name)
      nil -> nil
    end
  end

  defp get_or_create_unmatched_org do
    case Repo.get_by(Organization, domain: "_unmatched_") do
      %Organization{} = org ->
        {:ok, org}

      nil ->
        # Race condition handling: if a concurrent request creates the org
        # between our check and insert, catch the constraint error and re-query.
        attrs = %{
          name: "Unmatched Senders",
          domain: "_unmatched_",
          tier: :basic
        }

        %Organization{}
        |> Organization.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, org} ->
            {:ok, org}

          {:error, %Ecto.Changeset{errors: errors} = changeset} ->
            # Check if error is due to unique constraint on domain
            if Keyword.has_key?(errors, :domain) do
              # Concurrent insert won - fetch the existing record
              case Repo.get_by(Organization, domain: "_unmatched_") do
                %Organization{} = org -> {:ok, org}
                nil -> {:error, changeset}
              end
            else
              {:error, changeset}
            end
        end
    end
  end
end

defmodule Custyard.Email.SenderMatcher do
  @moduledoc """
  Match email sender to Contact/Organization.

  Supports two matching modes:
  1. `match/1` — domain-based matching (legacy, for unrouted webhooks)
  2. `match_within_org/2` — route-context matching (preferred, uses org from inbound route)

  Priority order for routing:
  1. Route context (org/project from inbound route)
  2. Contact match within route's org scope
  3. Global contact match (catchall only)
  4. Domain match (catchall, unknown sender)
  """

  alias Custyard.{Contact, Organization, Repo}
  import Ecto.Query

  def match(from_address) do
    email = extract_email(from_address)
    domain = extract_domain(email)

    case find_contact_by_email(email) do
      {:ok, contact} ->
        org = Repo.get!(Organization, contact.organization_id)
        {:ok, org, contact}

      :not_found ->
        case find_org_by_domain(domain) do
          {:ok, org} ->
            # Create contact for known org
            {:ok, contact} = create_contact(org, email, from_address)
            {:ok, org, contact}

          :not_found ->
            # Unknown sender - create "unmatched" org placeholder
            {:ok, org} = get_or_create_unmatched_org()
            {:ok, contact} = create_contact(org, email, from_address)
            {:ok, org, contact}
        end
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
        {:ok, contact} = create_contact(org, email, from_address)
        {:ok, org, contact}
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

  defp find_contact_by_email(email) do
    case Repo.get_by(Contact, email: email) do
      nil -> :not_found
      contact -> {:ok, contact}
    end
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
      nil ->
        %Organization{}
        |> Organization.changeset(%{
          name: "Unmatched Senders",
          domain: "_unmatched_",
          tier: :basic
        })
        |> Repo.insert()

      org ->
        {:ok, org}
    end
  end
end

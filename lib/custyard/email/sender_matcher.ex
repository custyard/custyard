defmodule Custyard.Email.SenderMatcher do
  @moduledoc "Match email sender to Contact/Organization"

  alias Custyard.{Repo, Organization, Contact}

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
        |> Organization.changeset(%{name: "Unmatched Senders", domain: "_unmatched_", tier: :basic})
        |> Repo.insert()

      org ->
        {:ok, org}
    end
  end
end

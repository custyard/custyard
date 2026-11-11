defmodule Custyard.Email.SenderMatcher do
  @moduledoc "Resolve sender identities only inside the receiving tenant."
  alias Custyard.{Contact, EmailAddress, Organization, Repo}
  import Ecto.Query

  @personal_domains ~w(gmail.com googlemail.com outlook.com hotmail.com live.com yahoo.com
    yahoo.ca yahoo.co.uk aol.com icloud.com me.com mac.com proton.me protonmail.com pm.me
    fastmail.com hey.com gmx.com gmx.de mail.com)

  def match_within_tenant(from, tenant_id, opts \\ []) when is_integer(tenant_id) do
    case {extract_email(from), resolve_existing(from, tenant_id)} do
      {nil, _} ->
        {:ok, nil, nil}

      {_email, :ambiguous} ->
        {:ok, nil, nil}

      {_email, {:contact, contact}} ->
        with_default_contact(Repo.get!(Organization, contact.organization_id), contact)

      {email, {:organization, org}} ->
        with_contact(org, email, from)

      {email, :none} ->
        case Keyword.get(opts, :organization_id) &&
               Repo.get_by(Organization,
                 id: Keyword.get(opts, :organization_id),
                 tenant_id: tenant_id
               ) do
          %Organization{} = org -> with_contact(org, email, from)
          nil -> create_customer(email, from, tenant_id)
        end
    end
  end

  def resolve_existing(from, tenant_id) when is_integer(tenant_id) do
    case extract_email(from) do
      nil -> :none
      email -> resolve_email(email, tenant_id)
    end
  end

  defp resolve_email(email, tenant_id) do
    contacts =
      Repo.all(
        from c in Contact, where: c.tenant_id == ^tenant_id and c.email == ^email, limit: 2
      )

    case contacts do
      [contact] -> {:contact, contact}
      [] -> resolve_identity(email, tenant_id)
      _multiple_contacts -> :ambiguous
    end
  end

  defp resolve_identity(email, tenant_id) do
    attrs = identity_attrs(email, tenant_id)

    case Repo.get_by(Organization, attrs) do
      nil -> :none
      organization -> {:organization, organization}
    end
  end

  defp identity_attrs(email, tenant_id) do
    domain = email |> String.split("@") |> List.last()

    if personal?(domain),
      do: [tenant_id: tenant_id, identity_kind: :email, identity_value: email],
      else: [tenant_id: tenant_id, identity_kind: :domain, identity_value: domain]
  end

  # Used only after a thread has already established its customer identity.
  def match_within_org(from, org_id) do
    org = Repo.get!(Organization, org_id)

    case extract_email(from) do
      nil -> {:ok, org, nil}
      email -> with_contact(org, email, from)
    end
  end

  defp create_customer(email, from, tenant_id) do
    identity = identity_attrs(email, tenant_id)
    attrs = identity |> Map.new() |> Map.merge(customer_attrs(identity, email, from))
    result = %Organization{} |> Organization.changeset(attrs) |> Repo.insert()

    case result do
      {:ok, org} -> with_contact(org, email, from)
      {:error, changeset} -> adopt_customer(identity, email, from, changeset)
    end
  end

  defp customer_attrs([tenant_id: _, identity_kind: :email, identity_value: _], email, from),
    do: %{domain: nil, name: extract_name(from) || email}

  defp customer_attrs(identity, _email, _from),
    do: %{domain: identity[:identity_value], name: identity[:identity_value]}

  defp adopt_customer(identity, email, from, changeset) do
    case Repo.get_by(Organization, identity) do
      nil -> {:error, changeset}
      org -> with_contact(org, email, from)
    end
  end

  defp personal?(domain),
    do: domain in Application.get_env(:custyard, :personal_email_domains, @personal_domains)

  defp with_contact(org, email, from) do
    existing = Repo.get_by(Contact, organization_id: org.id, email: email)

    result =
      if existing,
        do: {:ok, existing},
        else:
          %Contact{}
          |> Contact.changeset(%{
            tenant_id: org.tenant_id,
            organization_id: org.id,
            email: email,
            name: extract_name(from)
          })
          |> Repo.insert()

    case result do
      {:ok, contact} ->
        with_default_contact(org, contact)

      {:error, changeset} ->
        case Repo.get_by(Contact, organization_id: org.id, email: email) do
          nil -> {:error, changeset}
          contact -> with_default_contact(org, contact)
        end
    end
  end

  defp with_default_contact(%Organization{identity_kind: :email} = org, contact) do
    from(o in Organization,
      where: o.id == ^org.id and o.tenant_id == ^contact.tenant_id,
      where: is_nil(o.default_contact_id) and o.identity_value == ^contact.email
    )
    |> Repo.update_all(set: [default_contact_id: contact.id])

    {:ok, Repo.reload!(org), contact}
  end

  defp with_default_contact(org, contact), do: {:ok, org, contact}

  def extract_email(from) when is_binary(from) do
    candidate =
      case Regex.run(~r/<([^>]+)>/, from) do
        [_, email] -> email
        nil -> from
      end

    candidate = candidate |> String.trim() |> String.downcase()
    if EmailAddress.valid?(candidate), do: candidate
  end

  def extract_email(_), do: nil

  defp extract_name(from) do
    case Regex.run(~r/^([^<]+)</, from) do
      [_, name] -> if String.trim(name) != "", do: String.trim(name)
      nil -> nil
    end
  end
end

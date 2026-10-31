defmodule Custyard.Email.SenderMatcher do
  @moduledoc """
  Match email sender to Contact/Organization.

  Tenant-owned shared inboxes use `match_within_tenant/2` after header
  threading. Explicit customer routes keep `match_within_org/2`; `match/1`
  remains the legacy fallback for unrouted integrations.
  """

  require Custyard.Log, as: Log
  alias Custyard.{Contact, EmailAddress, Organization, Repo}
  import Ecto.Query

  # A mailbox at a shared provider identifies a person, not everyone using that
  # provider. Deployments can extend this list without changing routing code.
  @personal_domains ~w(gmail.com googlemail.com outlook.com hotmail.com live.com
    yahoo.com yahoo.ca yahoo.co.uk aol.com icloud.com me.com mac.com proton.me
    protonmail.com pm.me fastmail.com hey.com gmx.com gmx.de mail.com)

  @doc "Resolve or create customer identity only inside the receiving tenant."
  def match_within_tenant(from_address, tenant_id) when is_integer(tenant_id) do
    case extract_email(from_address) do
      email when is_binary(email) -> match_tenant_email(email, from_address, tenant_id)
      _ -> unmatched_tenant_customer(tenant_id)
    end
  end

  defp match_tenant_email(email, from_address, tenant_id) do
    contacts =
      from(c in Contact,
        join: o in Organization,
        on: c.organization_id == o.id,
        where: o.tenant_id == ^tenant_id and c.email == ^email,
        limit: 2,
        preload: [organization: o]
      )
      |> Repo.all()

    case contacts do
      [contact] -> {:ok, contact.organization, contact}
      [] -> create_tenant_customer(email, from_address, tenant_id)
      # A participant can belong to several customers after joining their
      # threads. New unthreaded mail then follows the sender's own business
      # domain or personal-address identity, never an arbitrary contact.
      _ambiguous -> create_tenant_customer(email, from_address, tenant_id)
    end
  end

  defp unmatched_tenant_customer(tenant_id) do
    attrs = %{
      tenant_id: tenant_id,
      intake_key: "unmatched",
      domain: nil,
      name: "Unmatched sender",
      tier: :standard
    }

    existing = Repo.get_by(Organization, tenant_id: tenant_id, intake_key: attrs.intake_key)

    with {:ok, organization} <- existing_or_insert_customer(existing, attrs),
         do: {:ok, organization, nil}
  end

  defp create_tenant_customer(email, from_address, tenant_id) do
    domain = extract_domain(email)

    personal? =
      domain in Application.get_env(:custyard, :personal_email_domains, @personal_domains)

    key = if personal?, do: "email:" <> email, else: "domain:" <> domain

    existing =
      if personal?,
        do: Repo.get_by(Organization, tenant_id: tenant_id, intake_key: key),
        else: Repo.get_by(Organization, tenant_id: tenant_id, domain: domain)

    attrs = %{
      tenant_id: tenant_id,
      intake_key: key,
      domain: if(personal?, do: nil, else: domain),
      name: if(personal?, do: extract_name(from_address) || email, else: domain),
      tier: :standard
    }

    with {:ok, org} <- existing_or_insert_customer(existing, attrs),
         {:ok, contact} <- create_contact(org, email, from_address) do
      {:ok, org, contact}
    end
  end

  defp existing_or_insert_customer(%Organization{} = org, _attrs), do: {:ok, org}

  defp existing_or_insert_customer(nil, attrs) do
    case %Organization{} |> Organization.changeset(attrs) |> Repo.insert() do
      {:ok, org} ->
        {:ok, org}

      {:error, changeset} ->
        # Concurrent first mail can create the same business/person. The unique
        # tenant key selects the winner without creating a second organization.
        winner =
          Repo.get_by(Organization, tenant_id: attrs.tenant_id, intake_key: attrs.intake_key) ||
            (attrs.domain &&
               Repo.get_by(Organization, tenant_id: attrs.tenant_id, domain: attrs.domain))

        case winner do
          %Organization{} = org -> {:ok, org}
          nil -> {:error, changeset}
        end
    end
  end

  def match(from_address) do
    case extract_email(from_address) do
      # No storable address (missing From, bare display name, chat user id):
      # file the message under the catchall with no contact rather than
      # rejecting it. Operator and portal views already render contactless
      # conversations, and the raw sender stays on the message row.
      nil -> with {:ok, org} <- get_or_create_unmatched_org(), do: {:ok, org, nil}
      email -> match_email(email, from_address)
    end
  end

  defp match_email(email, from_address) do
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
        Log.warning(:sender_organization_ambiguous,
          organization_id: org.id,
          organization_count: length(rest) + 1
        )

        {:ok, org, contact}
    end
  end

  @doc """
  Lookup-only sender resolution for the public intake flow.

  Same priority as `match/1` — exact contact match (oldest contact wins on
  multi-org ambiguity, with a logged warning), then organization-by-domain —
  but it never creates rows and never resolves to the `"_unmatched_"` sentinel
  organization: contacts auto-created inside the sentinel org by `match/1`'s
  catchall fallback are excluded from the contact lookup (falling through to
  domain resolution), and the sentinel is excluded from the domain path. The
  webhook pipeline and its auto-creating `match/1` are untouched.

  Returns `{:contact, contact}` | `{:organization, organization}` | `:none`.
  """
  def resolve(from_address) do
    case extract_email(from_address) do
      nil -> :none
      email -> resolve_email(email)
    end
  end

  @doc "Lookup-only contact/domain resolution inside a tenant; ambiguity never chooses arbitrarily."
  def resolve_existing(from_address, tenant_id) when is_integer(tenant_id) do
    case extract_email(from_address) do
      nil ->
        :none

      email ->
        contacts =
          from(c in Contact,
            join: o in Organization,
            on: o.id == c.organization_id,
            where: o.tenant_id == ^tenant_id and c.email == ^email,
            where: is_nil(o.domain) or o.domain != "_unmatched_",
            limit: 2
          )
          |> Repo.all()

        case contacts do
          [contact] -> {:contact, contact}
          [] -> resolve_tenant_domain(email, tenant_id)
          _ambiguous -> :none
        end
    end
  end

  def resolve_existing(_from_address, _tenant_id), do: :none

  defp resolve_tenant_domain(email, tenant_id) do
    case Repo.get_by(Organization, domain: extract_domain(email), tenant_id: tenant_id) do
      nil -> :none
      organization -> {:organization, organization}
    end
  end

  defp resolve_email(email) do
    domain = extract_domain(email)

    case find_linkable_contacts_by_email(email) do
      [] ->
        resolve_org_by_domain(domain)

      [contact] ->
        {:contact, contact}

      [contact | rest] ->
        # Oldest contact (first relationship) wins — same tie-break as match/1.
        Log.warning(:sender_organization_ambiguous,
          contact_id: contact.id,
          organization_id: contact.organization_id,
          organization_count: length(rest) + 1
        )

        {:contact, contact}
    end
  end

  # The "_unmatched_" sentinel org is an artifact of the webhook pipeline's
  # auto-creation fallback; it must never be offered as a resolution target.
  defp resolve_org_by_domain("_unmatched_"), do: :none

  defp resolve_org_by_domain(domain) do
    case find_org_by_domain(domain) do
      {:ok, org} -> {:organization, org}
      :not_found -> :none
    end
  end

  @doc """
  Match a sender within a specific organization (route-context matching).

  The organization is already known from the inbound route. We only need
  to find or create the contact within that org scope.
  """
  def match_within_org(from_address, org_id) do
    org = Repo.get!(Organization, org_id)

    case extract_email(from_address) do
      nil ->
        {:ok, org, nil}

      email ->
        case find_contact_in_org(email, org_id) do
          {:ok, contact} ->
            {:ok, org, contact}

          :not_found ->
            with {:ok, contact} <- create_contact(org, email, from_address) do
              {:ok, org, contact}
            end
        end
    end
  end

  @doc """
  Extract the downcased address from a sender string.

  Handles the `Name <email>` form. Returns `nil` when `from` carries nothing
  that can be stored as a contact: `nil` or non-string input, a blank string,
  a bare display name (`Name <>`), or a chat identifier such as a Slack user
  id. Validity is `Custyard.EmailAddress.valid?/1`, every rule
  `Contact.changeset/2` enforces, so an unstorable sender is detected before
  any insert.
  """
  @spec extract_email(term()) :: String.t() | nil
  def extract_email(from) when is_binary(from) do
    candidate =
      case Regex.run(~r/<([^>]+)>/, from) do
        [_, email] -> email
        nil -> from
      end

    candidate = candidate |> String.trim() |> String.downcase()

    if EmailAddress.valid?(candidate), do: candidate, else: nil
  end

  def extract_email(_from), do: nil

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

  # Contact lookup for resolve/1: same ordering as find_contacts_by_email/1,
  # but excludes contacts inside the "_unmatched_" sentinel org — resolve/1
  # must never offer the sentinel as a link target through either path. The
  # is_nil branch keeps contacts in domain-less organizations eligible.
  defp find_linkable_contacts_by_email(email) do
    from(c in Contact,
      join: o in Organization,
      on: o.id == c.organization_id,
      where: c.email == ^email and (is_nil(o.domain) or o.domain != "_unmatched_"),
      order_by: [asc: c.inserted_at]
    )
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
    |> case do
      {:ok, contact} ->
        {:ok, contact}

      # Two deliveries from a first-time sender (one email to two mailboxes
      # of the same organization, or a provider retry racing the original)
      # both miss the lookup and both insert; the loser hits the
      # (email, organization_id) unique index. Adopt the winner's row
      # instead of failing the delivery.
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :email) do
          case find_contact_in_org(email, org.id) do
            {:ok, contact} -> {:ok, contact}
            :not_found -> {:error, changeset}
          end
        else
          {:error, changeset}
        end
    end
  end

  defp extract_name(from) do
    case Regex.run(~r/^([^<]+)</, from) do
      [_, name] ->
        case String.trim(name) do
          "" -> nil
          name -> name
        end

      nil ->
        nil
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

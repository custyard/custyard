defmodule Custyard.PortalCredentials do
  @moduledoc "Issue and revoke customer portal links without storing bearer tokens."
  import Ecto.Query

  alias Custyard.{
    Contact,
    Organization,
    StaffAccess,
    StaffAccount,
    PortalCredential,
    Repo,
    Scope,
    Tenant
  }

  def issue(scope, organization_id, contact_id \\ nil)

  def issue(%Scope{tenant_id: tenant_id, role: "admin"} = scope, organization_id, contact_id) do
    with_admin(scope, fn -> do_issue(tenant_id, organization_id, contact_id) end)
  end

  def issue(_, _, _), do: {:error, :unauthorized}

  defp do_issue(tenant_id, organization_id, contact_id) do
    with %Organization{tenant_id: ^tenant_id} <- Repo.get(Organization, organization_id),
         true <- contact_matches?(contact_id, tenant_id, organization_id) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      case %PortalCredential{}
           |> PortalCredential.changeset(%{
             tenant_id: tenant_id,
             organization_id: organization_id,
             contact_id: contact_id,
             token_hash: hash(token)
           })
           |> Repo.insert() do
        {:ok, credential} -> {:ok, credential, token}
        error -> error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def authenticate(token, tenant_id) when is_binary(token) and is_integer(tenant_id) do
    token_hash = hash(token)

    from(c in PortalCredential,
      join: t in Tenant,
      on: t.id == c.tenant_id,
      where: c.tenant_id == ^tenant_id and c.token_hash == ^token_hash,
      where: is_nil(c.revoked_at) and t.status == "active",
      preload: [:organization, :contact]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      credential -> {:ok, credential}
    end
  end

  def authenticate(_, _), do: {:error, :not_found}

  @doc "Contact attribution for portal requests; an explicit credential contact wins over the customer default."
  def reply_contact(%PortalCredential{
        tenant_id: tenant_id,
        organization_id: org_id,
        contact_id: id
      }) do
    if id do
      Repo.get_by(Contact, id: id, tenant_id: tenant_id, organization_id: org_id)
    else
      case Repo.get_by(Organization, id: org_id, tenant_id: tenant_id) do
        nil -> nil
        org -> Custyard.Organizations.default_contact(org)
      end
    end
  end

  def revoke(
        %Scope{tenant_id: tenant_id, role: "admin"} = scope,
        %PortalCredential{tenant_id: tenant_id} = credential
      ) do
    with_admin(scope, fn ->
      case Repo.get_by(PortalCredential, id: credential.id, tenant_id: tenant_id) do
        nil ->
          {:error, :not_found}

        current ->
          current
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
          |> Repo.update()
      end
    end)
  end

  def revoke(_, _), do: {:error, :unauthorized}

  defp with_admin(scope, fun) do
    Repo.transaction(fn ->
      staff = scope.staff_id && StaffAccess.lock_current(%StaffAccount{id: scope.staff_id})

      case {staff, Repo.get(Tenant, scope.tenant_id)} do
        {%StaffAccount{tenant_id: id, role: "admin", session_claim: claim},
         %Tenant{status: "active"}}
        when id == scope.tenant_id and claim == scope.session_claim ->
          case fun.() do
            {:error, reason} -> Repo.rollback(reason)
            result -> result
          end

        _ ->
          Repo.rollback(:unauthorized)
      end
    end)
    |> case do
      {:ok, result} -> result
      error -> error
    end
  end

  def list(%Scope{tenant_id: tenant_id, role: role} = scope, organization_id)
      when role in ["admin", "agent"] do
    if Scope.current_staff(scope),
      do:
        Repo.all(
          from c in PortalCredential,
            where: c.tenant_id == ^tenant_id and c.organization_id == ^organization_id,
            order_by: [desc: c.id],
            preload: [:contact]
        ),
      else: []
  end

  def list(_, _), do: []

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  defp contact_matches?(nil, _, _), do: true

  defp contact_matches?(id, tenant_id, organization_id) do
    case Repo.get(Contact, id) do
      %Contact{organization_id: ^organization_id} ->
        Repo.exists?(
          from o in Organization, where: o.id == ^organization_id and o.tenant_id == ^tenant_id
        )

      _ ->
        false
    end
  end
end

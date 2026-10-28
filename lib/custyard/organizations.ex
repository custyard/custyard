defmodule Custyard.Organizations do
  @moduledoc """
  Customer organization operations.
  """

  require Logger

  alias Custyard.{
    AuditEvent,
    Contact,
    Thread,
    Threads,
    Organization,
    StaffAccount,
    Prospect,
    Repo,
    Scoring,
    Slugs
  }

  import Ecto.Query

  def list(%Custyard.Scope{tenant_id: tenant_id} = scope) do
    if Custyard.Scope.current_staff(scope),
      do: Repo.all(from o in Organization, where: o.tenant_id == ^tenant_id, order_by: o.name),
      else: []
  end

  def get(%Custyard.Scope{tenant_id: tenant_id} = scope, id) do
    if Custyard.Scope.current_staff(scope),
      do: Repo.get_by(Organization, id: id, tenant_id: tenant_id)
  end

  def create(%Custyard.Scope{} = scope, attrs) do
    with_scope(scope, fn _staff ->
      attrs =
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
        |> Map.put("tenant_id", scope.tenant_id)

      create_organization(attrs)
    end)
  end

  def update(%Custyard.Scope{} = scope, %Organization{} = org, attrs) do
    with_scope(scope, fn _staff ->
      case Repo.get_by(Organization, id: org.id, tenant_id: scope.tenant_id) do
        nil -> {:error, :unauthorized}
        current -> update_organization(current, attrs)
      end
    end)
  end

  def delete(%Custyard.Scope{} = scope, %Organization{} = org) do
    with_scope(scope, fn _staff ->
      case Repo.get_by(Organization, id: org.id, tenant_id: scope.tenant_id) do
        nil -> {:error, :unauthorized}
        current -> delete_organization(current)
      end
    end)
  end

  def convert(%Custyard.Scope{} = scope, %Thread{tenant_id: tenant_id} = thread, attrs) do
    result =
      if tenant_id == scope.tenant_id,
        do: with_scope(scope, fn staff -> convert_prospect(thread, attrs, staff) end),
        else: {:error, :unauthorized}

    case result do
      {:ok, {converted, organization, staff}} ->
        handle_convert_result({:ok, converted}, organization, staff)

      error ->
        error
    end
  end

  defp with_scope(%Custyard.Scope{} = scope, fun) do
    Repo.transaction(fn ->
      staff = Custyard.StaffAccess.lock_current(%StaffAccount{id: scope.staff_id})

      if staff && staff.tenant_id == scope.tenant_id && staff.role == "admin" &&
           StaffAccount.session_claim_matches?(staff, scope.session_claim) &&
           Custyard.Tenants.active?(scope.tenant_id) do
        case fun.(staff) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:unauthorized)
      end
    end)
  end

  def get!(%Custyard.Scope{} = scope, id) do
    get(scope, id) || raise Ecto.NoResultsError, queryable: Organization
  end

  @doc """
  List contacts for an organization.
  """
  def list_contacts(%Custyard.Scope{tenant_id: tenant_id} = scope, org_id) do
    if Custyard.Scope.current_staff(scope) do
      Repo.all(
        from c in Contact,
          where: c.organization_id == ^org_id and c.tenant_id == ^tenant_id,
          order_by: [asc: c.name, asc: c.email]
      )
    else
      []
    end
  end

  @doc "List visible organizations with their thread counts."
  def list_with_counts(%Custyard.Scope{tenant_id: tenant_id} = scope) do
    if Custyard.Scope.current_staff(scope) do
      Organization
      |> where([o], o.tenant_id == ^tenant_id)
      |> join(:left, [o], c in assoc(o, :threads))
      |> group_by([o], o.id)
      |> select([o, c], %{org: o, thread_count: count(c.id)})
      |> order_by([o], asc: o.name)
      |> Repo.all()
    else
      []
    end
  end

  defp create_organization(attrs) do
    %Organization{} |> Organization.changeset(attrs) |> Repo.insert()
  end

  defp update_organization(%Organization{} = org, attrs) do
    org
    |> Organization.changeset(attrs)
    |> reject_tenant_move()
    |> Repo.update()
  end

  defp reject_tenant_move(changeset) do
    if Ecto.Changeset.changed?(changeset, :tenant_id),
      do:
        Ecto.Changeset.add_error(
          changeset,
          :tenant_id,
          "cannot be changed for an existing customer"
        ),
      else: changeset
  end

  @doc """
  Build a changeset for an organization.
  """
  def change_organization(%Organization{} = org, attrs \\ %{}) do
    Organization.changeset(org, attrs)
  end

  defp delete_organization(%Organization{} = org) do
    # Count associated records for audit logging
    contact_count =
      Repo.aggregate(from(c in Contact, where: c.organization_id == ^org.id), :count)

    thread_count =
      Repo.aggregate(from(c in Thread, where: c.organization_id == ^org.id), :count)

    # Log deletion details before executing
    Logger.warning(
      "Deleting organization",
      organization_id: org.id,
      organization_name: org.name,
      organization_domain: org.domain,
      contacts_to_delete: contact_count,
      threads_to_delete: thread_count
    )

    result =
      if Repo.exists?(
           from(a in Custyard.Acknowledgments.Acknowledgment,
             where: a.tenant_id == ^org.tenant_id and a.organization_id == ^org.id
           )
         ) do
        {:error, :retained_evidence}
      else
        delete_customer_records(org)
      end

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
          %{count: 1, contacts: contact_count, threads: thread_count},
          %{organization_id: org.id, organization_name: org.name}
        )

        {:ok, deleted}

      {:error, _} = error ->
        Logger.error("Failed to delete organization", organization_id: org.id)
        error
    end
  end

  defp delete_customer_records(org) do
    Repo.transaction(fn ->
      {threads, projects} = customer_work_queries(org)
      detach_customer_audit(org, threads, projects)
      detach_customer_infrastructure(org, threads, projects)
      delete_customer_claims(org, threads)
      delete_customer_identity(org)
      delete_customer_work(org, threads, projects)

      Repo.delete_all(
        from c in Contact, where: c.tenant_id == ^org.tenant_id and c.organization_id == ^org.id
      )

      case Repo.delete(org) do
        {:ok, deleted} -> deleted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp customer_work_queries(org) do
    threads =
      from(c in Thread,
        where: c.tenant_id == ^org.tenant_id and c.organization_id == ^org.id,
        select: c.id
      )

    projects =
      from(p in Custyard.Project,
        where: p.tenant_id == ^org.tenant_id and p.organization_id == ^org.id,
        select: p.id
      )

    {threads, projects}
  end

  defp detach_customer_audit(org, threads, projects) do
    from(a in AuditEvent,
      where: a.tenant_id == ^org.tenant_id,
      where:
        a.organization_id == ^org.id or a.thread_id in subquery(threads) or
          a.project_id in subquery(projects)
    )
    |> Repo.update_all(set: [organization_id: nil, thread_id: nil, project_id: nil])
  end

  defp detach_customer_infrastructure(org, threads, projects) do
    from(e in Custyard.EmailConnection,
      where: e.tenant_id == ^org.tenant_id,
      where: e.latest_received_thread_id in subquery(threads)
    )
    |> Repo.update_all(set: [latest_received_thread_id: nil])

    from(c in Custyard.InboundChannel,
      where: c.tenant_id == ^org.tenant_id and c.default_organization_id == ^org.id
    )
    |> Repo.update_all(set: [default_organization_id: nil])

    from(c in Custyard.InboundChannel,
      where: c.tenant_id == ^org.tenant_id and c.default_project_id in subquery(projects)
    )
    |> Repo.update_all(set: [default_project_id: nil])

    from(p in Custyard.Project,
      where: p.tenant_id == ^org.tenant_id and p.thread_id in subquery(threads)
    )
    |> Repo.update_all(set: [thread_id: nil])
  end

  defp delete_customer_claims(org, threads) do
    from(s in Custyard.Slug,
      where: s.tenant_id == ^org.tenant_id,
      where: s.organization_id == ^org.id or s.thread_id in subquery(threads)
    )
    |> Repo.delete_all()
  end

  defp delete_customer_identity(org) do
    from(p in Custyard.PortalCredential,
      where: p.tenant_id == ^org.tenant_id and p.organization_id == ^org.id
    )
    |> Repo.delete_all()

    from(b in Custyard.Acknowledgments.OrganizationBinding,
      where: b.tenant_id == ^org.tenant_id and b.organization_id == ^org.id
    )
    |> Repo.delete_all()

    from(r in Custyard.InboundChannelRejection,
      where: r.tenant_id == ^org.tenant_id and r.organization_id == ^org.id
    )
    |> Repo.delete_all()
  end

  defp delete_customer_work(org, threads, projects) do
    from(t in Custyard.WorkItem,
      where: t.tenant_id == ^org.tenant_id,
      where:
        t.organization_id == ^org.id or t.thread_id in subquery(threads) or
          t.project_id in subquery(projects)
    )
    |> Repo.delete_all()

    Repo.delete_all(from(c in Thread, where: c.id in subquery(threads)))
    Repo.delete_all(from(p in Custyard.Project, where: p.id in subquery(projects)))
  end

  defp convert_prospect(
         %Thread{organization_id: nil, source: :public_intake} = thread,
         org_attrs,
         %StaffAccount{} = staff
       ) do
    org_attrs =
      Map.new(org_attrs, fn {key, value} -> {to_string(key), value} end)
      |> Map.put("tenant_id", thread.tenant_id)

    case create_organization(org_attrs) do
      {:ok, organization} ->
        case do_convert_or_compensate(thread, organization) do
          {:ok, converted} -> {:ok, {converted, organization, staff}}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp convert_prospect(%Thread{}, _org_attrs, %StaffAccount{}),
    do: {:error, :not_convertible}

  # The organization (and its provisioned inbound route) is already committed
  # when step 2 runs; an exception there must not leave it behind as an orphan
  # that blocks a retry on the domain unique index.
  defp do_convert_or_compensate(thread, organization) do
    do_convert(thread, organization)
  rescue
    error ->
      # with_scope/2 owns the transaction containing customer creation.
      # Let that transaction roll back rather than write on a failed connection.
      unless Repo.in_transaction?(), do: delete_organization(organization)
      reraise error, __STACKTRACE__
  end

  defp do_convert(thread, organization) do
    Repo.transaction(fn ->
      prospect = Repo.get_by(Prospect, thread_id: thread.id)

      case Slugs.promote(thread, organization) do
        {:ok, _slug} -> :ok
        {:error, :not_found} -> :ok
      end

      contact = maybe_create_contact(prospect, organization)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      set = [organization_id: organization.id, updated_at: now] |> maybe_put_contact(contact)

      {count, _} =
        Repo.update_all(
          from(c in Thread, where: c.id == ^thread.id and is_nil(c.organization_id)),
          set: set
        )

      case count do
        1 ->
          Repo.get!(Thread, thread.id) |> Repo.preload([:organization, :contact])

        0 ->
          Repo.rollback(:already_converted)
      end
    end)
  end

  defp maybe_create_contact(%Prospect{email: email}, organization) when is_binary(email) do
    case %Contact{}
         |> Contact.changeset(%{
           email: email,
           organization_id: organization.id,
           tenant_id: organization.tenant_id
         })
         |> Repo.insert() do
      {:ok, contact} -> contact
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp maybe_create_contact(_prospect, _organization), do: nil

  defp maybe_put_contact(set, nil), do: set
  defp maybe_put_contact(set, %Contact{id: id}), do: Keyword.put(set, :contact_id, id)

  defp handle_convert_result({:ok, thread}, organization, staff) do
    Scoring.calculate_and_cache(thread.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "threads",
      {:thread_updated, thread.id}
    )

    Threads.broadcast_to_org(
      thread.organization_id,
      {:thread_updated, thread.id}
    )

    record_conversion_audit(thread, organization, staff)

    {:ok, thread}
  end

  # Append-only audit trail for the conversion (AuditEvent.create pattern,
  # same as the slug-release audit write, including staff attribution).
  # A logging failure never blocks the conversion — it already committed.
  # organization_id is deliberately omitted from the payload: it is already
  # the row's schema column.
  defp record_conversion_audit(thread, organization, staff) do
    case AuditEvent.create(%{
           event_type: :prospect_converted,
           source: "staff",
           payload: %{
             "organization_name" => organization.name,
             "staff_id" => staff.id,
             "staff_email" => staff.email
           },
           thread_id: thread.id,
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

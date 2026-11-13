defmodule Custyard.Tasks do
  @moduledoc """
  Every task of a tenant in one list, whatever it is attached to: a
  conversation, a project, a customer, or a combination.

  The list is scoped the way `Custyard.Threads.list/2` is. The tenant comes
  from the scope and a current staff member is required. Staff accounts are
  not limited to certain customers, so every staff member of a tenant sees
  every task of that tenant, as they see every conversation.
  """

  import Ecto.Query

  alias Custyard.{
    Organization,
    Projects,
    Repo,
    Scope,
    StaffAccess,
    StaffAccount,
    Tenants,
    Threads,
    WorkItem
  }

  @filters ~w(open due upcoming no_date done all)
  @default_filter "open"

  # What a row shows. The joined conversation, project and customer are cut
  # down to these fields, so a long list stays a small response.
  @row_fields [
    :id,
    :tenant_id,
    :title,
    :state,
    :portal_visible,
    :due_at,
    :thread_id,
    :project_id,
    :organization_id,
    :inserted_at,
    :updated_at,
    thread: [:id, :subject],
    project: [:id, :title],
    organization: [:id, :public_id, :name]
  ]

  @doc "The filter names `list/2` and `counts/2` understand."
  def filters, do: @filters

  @doc "The filter used when none is given: every unfinished task."
  def default_filter, do: @default_filter

  @doc """
  The tenant's tasks.

  Options:

    * `:filter` - one of `filters/0` (default `"open"`). An unknown name
      lists the default.
      * `"open"` - every unfinished task
      * `"due"` - unfinished and the due date is reached
      * `"upcoming"` - unfinished with a later due date
      * `"no_date"` - unfinished without a due date
      * `"done"` - finished
      * `"all"` - everything
    * `:reverse` - `true` lists the exact reverse of the default order
    * `:organization_id` - only the tasks of this customer
    * `:now` - the moment that separates due from upcoming (default: the
      current time)

  Unfinished tasks come first, by due date with undated tasks last, then
  newest first. Finished tasks follow, most recently updated first.

  Each task carries what a row shows, loaded by the same query: `thread`
  (id and subject), `project` (id and title) and `organization` (id, public
  id and name). `organization` is the customer the task belongs to: its own,
  or else the customer of its conversation or project. Tasks of project
  templates are left out.
  """
  def list(%Scope{tenant_id: tenant_id} = scope, opts \\ []) do
    if Scope.current_staff(scope), do: list_tasks(tenant_id, opts, now(opts)), else: []
  end

  @doc """
  How many tasks each filter lists, keyed by filter name.

  Takes the `:organization_id` and `:now` options of `list/2` and applies the
  same rules, so each count equals the length of the matching `list/2`
  result. One query, whatever the number of filters.
  """
  def counts(%Scope{tenant_id: tenant_id} = scope, opts \\ []) do
    if Scope.current_staff(scope),
      do: tenant_id |> count_tasks(opts, now(opts)) |> Map.take(@filters),
      else: no_counts()
  end

  @doc """
  The list and the counts for one page view: `%{tasks: list, counts: map,
  next_due_at: datetime or nil}`.

  Takes the options of `list/2`. The staff member is checked once and both
  queries use the same moment, so the chips and the list always agree.
  `next_due_at` is when the next upcoming task becomes due, which is when the
  page has to load again; it comes from the counts query.
  """
  def page(%Scope{tenant_id: tenant_id} = scope, opts \\ []) do
    if Scope.current_staff(scope) do
      now = now(opts)
      {next_due_at, counts} = tenant_id |> count_tasks(opts, now) |> Map.pop("next_due_at")
      %{tasks: list_tasks(tenant_id, opts, now), counts: counts, next_due_at: next_due_at}
    else
      %{tasks: [], counts: no_counts(), next_due_at: nil}
    end
  end

  @doc """
  Set the state of a task from the list, for example to mark it done or to
  reopen it.

  Authorization and broadcasts are those of the page the task lives on. A
  task of a conversation goes through `Custyard.Threads.with_access/3` and
  `Custyard.Threads.update_task_state/2`, as the task toggle of the
  conversation page does. A task of a project alone goes through
  `Custyard.Projects.with_access/4`, as the project page does. A task
  attached only to a customer needs a current staff member of its tenant.

  Returns `{:ok, task}`, `{:error, :unauthorized}`, `{:error, :not_found}`
  when the task is gone or has moved, or `{:error, changeset}`.
  """
  def set_state(%Scope{} = scope, %WorkItem{thread_id: thread_id} = task, new_state)
      when is_integer(thread_id) do
    Threads.with_access(scope, thread_id, fn thread, _staff ->
      with {:ok, current} <- current_task(task, thread.tenant_id, thread_id: thread.id),
           do: Threads.update_task_state(current, new_state)
    end)
  end

  def set_state(%Scope{} = scope, %WorkItem{project_id: project_id} = task, new_state)
      when is_integer(project_id) do
    Projects.with_access(
      scope,
      project_id,
      fn project, _staff ->
        with {:ok, current} <- current_task(task, project.tenant_id, project_id: project.id),
             do: Projects.update_task_state(current, new_state, broadcast?: false)
      end,
      broadcast_project?: true
    )
  end

  def set_state(%Scope{} = scope, %WorkItem{} = task, new_state) do
    case Scope.current_staff(scope) do
      nil ->
        {:error, :unauthorized}

      staff ->
        with_current_staff(staff, fn current_staff ->
          with {:ok, current} <- current_task(task, current_staff.tenant_id, []),
               do: Threads.update_task_state(current, new_state)
        end)
    end
  end

  # The task as it is now, read after the lock is taken. The row on screen
  # can be stale: deleted in another session, or moved since the page loaded.
  defp current_task(%WorkItem{id: id}, tenant_id, parent) do
    case Repo.get_by(WorkItem, [id: id, tenant_id: tenant_id] ++ parent) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  # The checks Threads.with_access/3 makes before a write, for a task that
  # has no conversation or project to lock.
  defp with_current_staff(%StaffAccount{} = staff, fun) do
    Repo.transaction(fn ->
      with %StaffAccount{} = current_staff <- StaffAccess.lock_current(staff),
           true <- StaffAccount.session_claim_matches?(current_staff, staff.session_claim),
           true <- Tenants.active?(current_staff.tenant_id) do
        case fun.(current_staff) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        _ -> Repo.rollback(:unauthorized)
      end
    end)
  end

  defp list_tasks(tenant_id, opts, now) do
    filter = Keyword.get(opts, :filter, @default_filter)

    query =
      from([task: t, thread: c, project: p, customer: o] in visible(tenant_id, opts),
        where: ^member(filter, now),
        # Finished tasks sort apart from the rest and by their own date. The
        # id settles ties, so the reversed list is the exact reverse.
        order_by: [
          asc: fragment("CASE WHEN ? THEN 1 ELSE 0 END", t.state == :done),
          asc_nulls_last:
            fragment("CASE WHEN ? THEN NULL ELSE ? END", t.state == :done, t.due_at),
          desc: fragment("CASE WHEN ? THEN ? END", t.state == :done, t.updated_at),
          desc: t.inserted_at,
          desc: t.id
        ],
        select: struct(t, ^@row_fields),
        preload: [thread: c, project: p, organization: o]
      )

    query = if Keyword.get(opts, :reverse, false), do: reverse_order(query), else: query
    Repo.all(query)
  end

  # One row of totals. Each total filters on the rule the list uses for that
  # name, so a count cannot drift from the list behind it.
  defp count_tasks(tenant_id, opts, now) do
    totals =
      Map.new(@filters, fn name ->
        {name, dynamic([task: t], filter(count(t.id), ^member(name, now)))}
      end)

    next_due_at =
      dynamic([task: t], type(filter(min(t.due_at), ^member("upcoming", now)), :utc_datetime))

    tenant_id
    |> visible(opts)
    |> select(^Map.put(totals, "next_due_at", next_due_at))
    |> Repo.one()
  end

  defp no_counts, do: Map.new(@filters, &{&1, 0})

  # Every task the page may show, with what its row reads from.
  defp visible(tenant_id, opts) do
    from(t in WorkItem,
      as: :task,
      left_join: c in assoc(t, :thread),
      as: :thread,
      left_join: p in assoc(t, :project),
      as: :project,
      # A task added to a conversation before the conversation was linked to
      # a customer has no customer of its own. It belongs to the customer of
      # its conversation or project.
      left_join: o in Organization,
      as: :customer,
      on:
        o.tenant_id == t.tenant_id and
          o.id == coalesce(t.organization_id, coalesce(c.organization_id, p.organization_id)),
      where: t.tenant_id == ^tenant_id,
      # A template's tasks are copied into new projects. They are not work
      # to do, so they stay out, as templates stay out of the project list.
      where: is_nil(p.id) or p.is_template == false
    )
    |> for_customer(Keyword.get(opts, :organization_id))
  end

  defp for_customer(query, nil), do: query

  defp for_customer(query, organization_id) when is_integer(organization_id),
    do: where(query, [customer: o], o.id == ^organization_id)

  # Which tasks a filter lists.
  defp member("due", now),
    do: dynamic([task: t], t.state != :done and not is_nil(t.due_at) and t.due_at <= ^now)

  defp member("upcoming", now), do: dynamic([task: t], t.state != :done and t.due_at > ^now)
  defp member("no_date", _now), do: dynamic([task: t], t.state != :done and is_nil(t.due_at))
  defp member("done", _now), do: dynamic([task: t], t.state == :done)
  defp member("all", _now), do: dynamic(true)
  defp member(_open, _now), do: dynamic([task: t], t.state != :done)

  # Due dates are stored to the second, so the moment they are compared with
  # is cut to the second too.
  defp now(opts) do
    opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.truncate(:second)
  end
end

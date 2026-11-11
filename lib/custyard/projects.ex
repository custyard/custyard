defmodule Custyard.Projects do
  @moduledoc """
  Context for project queries and operations.
  """

  alias Custyard.{Authorization, StaffAccess, StaffAccount, Project, Repo, WorkItem}
  import Ecto.Query

  def list(%Custyard.Scope{} = scope, opts \\ []) do
    case staff_for_scope(scope) do
      nil -> []
      staff -> list_for_staff(staff, opts)
    end
  end

  def get(%Custyard.Scope{} = scope, id) do
    case staff_for_scope(scope) do
      nil -> nil
      staff -> get_project_for_staff(id, staff)
    end
  end

  def create(%Custyard.Scope{} = scope, attrs) do
    case staff_for_scope(scope) do
      nil -> {:error, :unauthorized}
      staff -> create_project_for_staff(attrs, staff)
    end
  end

  def update(%Custyard.Scope{} = scope, %Project{} = project, attrs) do
    case staff_for_scope(scope) do
      nil -> {:error, :unauthorized}
      staff -> update_project_for_staff(project, attrs, staff)
    end
  end

  def delete(%Custyard.Scope{} = scope, %Project{} = project) do
    case staff_for_scope(scope) do
      nil -> {:error, :unauthorized}
      staff -> delete_project_for_staff(project, staff)
    end
  end

  def with_access(%Custyard.Scope{} = scope, id, fun, opts \\ []) do
    case staff_for_scope(scope) do
      nil -> {:error, :unauthorized}
      staff -> with_staff_access(id, staff, fun, opts)
    end
  end

  defp staff_for_scope(scope), do: Custyard.Scope.current_staff(scope)

  defp list_for_staff(%StaffAccount{} = staff, opts) do
    requested_org_id = Keyword.get(opts, :organization_id)

    query =
      from(p in Project,
        where: p.is_template == false,
        order_by: [desc: p.inserted_at],
        preload: [:tasks, :organization]
      )
      |> scope_to_staff(staff)

    query =
      if is_integer(requested_org_id) do
        from(p in query, where: p.organization_id == ^requested_org_id)
      else
        query
      end

    query |> Repo.all() |> Enum.map(&with_progress/1)
  end

  defp scope_to_staff(query, %StaffAccount{tenant_id: tenant_id})
       when is_integer(tenant_id),
       do: from(p in query, where: p.tenant_id == ^tenant_id)

  defp scope_to_staff(query, %StaffAccount{}), do: from(p in query, where: false)

  @doc """
  List projects for a specific organization (staff view).
  """
  def list_for_organization(%Custyard.Scope{tenant_id: tenant_id}, org_id) do
    from(p in Project,
      where: p.organization_id == ^org_id and p.tenant_id == ^tenant_id,
      where: p.is_template == false,
      order_by: [desc: p.inserted_at],
      preload: [:tasks, :organization]
    )
    |> Repo.all()
    |> Enum.map(&with_progress/1)
  end

  @doc """
  List portal-visible projects for an organization.
  """
  def list_portal_visible(org_id) do
    visible_tasks = from(t in WorkItem, where: t.portal_visible == true)

    from(p in Project,
      where: p.organization_id == ^org_id,
      where: p.portal_visible == true,
      order_by: [desc: p.inserted_at],
      preload: [tasks: ^visible_tasks]
    )
    |> Repo.all()
    |> Enum.map(&with_progress/1)
  end

  @doc """
  Get a single project by ID for portal viewing.
  Returns `{:ok, project}` or `{:error, :not_found}` or `{:error, :not_visible}`.
  """
  def get_portal_project(id, org_id) do
    case Repo.get(Project, id) do
      nil ->
        {:error, :not_found}

      project ->
        cond do
          project.organization_id != org_id ->
            {:error, :not_found}

          not project.portal_visible ->
            {:error, :not_visible}

          true ->
            project =
              project
              |> Repo.preload(
                tasks:
                  from(t in WorkItem, where: t.portal_visible == true, order_by: t.inserted_at)
              )
              |> with_progress()

            {:ok, project}
        end
    end
  end

  defp get_project_for_staff(id, %StaffAccount{} = staff) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> get_project_for_staff(int_id, staff)
      _ -> nil
    end
  end

  defp get_project_for_staff(id, %StaffAccount{} = staff) when is_integer(id) do
    query = from(p in Project, where: p.id == ^id) |> scope_to_staff(staff)

    case Repo.one(query) do
      nil -> nil
      project -> project |> Repo.preload(:tasks) |> with_progress()
    end
  end

  defp get_project_for_staff(_id, %StaffAccount{}), do: nil

  def get!(%Custyard.Scope{} = scope, id) do
    get(scope, id) || raise Ecto.NoResultsError, queryable: Project
  end

  defp create_project_for_staff(attrs, %StaffAccount{} = staff) do
    result =
      Repo.transaction(fn ->
        current_staff = StaffAccess.lock_current(staff)

        attrs = stamp_project_tenant(attrs, current_staff)

        changeset = Project.changeset(%Project{}, attrs)

        destination_id = Ecto.Changeset.get_field(changeset, :organization_id)

        if authorized_project_creator?(current_staff, staff, destination_id) do
          case Repo.insert(changeset) do
            {:ok, project} -> project
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          Repo.rollback(:unauthorized)
        end
      end)

    case result do
      {:ok, project} ->
        broadcast_org_project(project.organization_id, {:project_created, project.id})
        result

      error ->
        error
    end
  end

  defp stamp_project_tenant(attrs, %StaffAccount{tenant_id: id}) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end) |> Map.put("tenant_id", id)
  end

  defp stamp_project_tenant(attrs, _), do: attrs

  defp authorized_project_creator?(%StaffAccount{} = current, original, destination_id) do
    current.tenant_id == original.tenant_id && current.role == original.role &&
      StaffAccount.session_claim_matches?(current, original.session_claim) &&
      Custyard.Tenants.active?(current.tenant_id) &&
      Authorization.can_manage_project?(current, destination_id)
  end

  defp authorized_project_creator?(_, _, _), do: false

  defp update_project_for_staff(%Project{} = project, attrs, %StaffAccount{} = staff) do
    case with_staff_access(project.id, staff, fn current, current_staff ->
           changeset = Project.changeset(current, attrs)
           destination_id = Ecto.Changeset.get_field(changeset, :organization_id)

           if Authorization.can_manage_project?(current_staff, current.organization_id) and
                Authorization.can_manage_project?(current_staff, destination_id) do
             case update_project_and_tasks(current, attrs) do
               {:ok, updated} -> {:ok, {updated, current.organization_id}}
               error -> error
             end
           else
             {:error, :unauthorized}
           end
         end) do
      {:ok, {updated, old_org_id}} ->
        broadcast_project_update(updated.id)

        if old_org_id != updated.organization_id do
          broadcast_org_project(old_org_id, {:project_updated, updated.id})
        end

        {:ok, updated}

      error ->
        error
    end
  end

  defp update_project_and_tasks(project, attrs) do
    changeset = project |> Project.changeset(attrs) |> validate_task_move()

    with {:ok, updated} <- Repo.update(changeset) do
      if updated.organization_id != project.organization_id do
        Repo.update_all(from(t in WorkItem, where: t.project_id == ^project.id),
          set: [
            organization_id: updated.organization_id,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        {:ok, Repo.preload(updated, :tasks, force: true)}
      else
        {:ok, updated}
      end
    end
  end

  defp validate_task_move(changeset) do
    if changeset.valid? and Ecto.Changeset.changed?(changeset, :organization_id) do
      organization_id = Ecto.Changeset.get_field(changeset, :organization_id)

      thread_orgs =
        Repo.all(
          from(t in WorkItem,
            join: c in Custyard.Thread,
            on: c.id == t.thread_id,
            where: t.project_id == ^changeset.data.id,
            select: c.organization_id
          )
        )

      if Enum.any?(thread_orgs, &(&1 != organization_id)) do
        Ecto.Changeset.add_error(
          changeset,
          :organization_id,
          "cannot move tasks linked to another customer's thread"
        )
      else
        changeset
      end
    else
      changeset
    end
  end

  defp delete_project_for_staff(%Project{} = project, %StaffAccount{} = staff) do
    case with_staff_access(project.id, staff, fn current, current_staff ->
           if Authorization.can_manage_project?(current_staff, current.organization_id) do
             delete_project_records(current)
           else
             {:error, :unauthorized}
           end
         end) do
      {:ok, deleted} = result ->
        broadcast_org_project(deleted.organization_id, {:project_deleted, deleted.id})
        result

      error ->
        error
    end
  end

  defp delete_project_records(project) do
    Repo.transaction(fn ->
      from(t in WorkItem,
        where: t.tenant_id == ^project.tenant_id and t.project_id == ^project.id
      )
      |> Repo.delete_all()

      from(c in Custyard.Thread,
        where: c.tenant_id == ^project.tenant_id and c.project_id == ^project.id
      )
      |> Repo.update_all(set: [project_id: nil])

      from(c in Custyard.InboundChannel,
        where: c.tenant_id == ^project.tenant_id and c.default_project_id == ^project.id
      )
      |> Repo.update_all(set: [default_project_id: nil])

      from(a in Custyard.AuditEvent,
        where: a.tenant_id == ^project.tenant_id and a.project_id == ^project.id
      )
      |> Repo.update_all(set: [project_id: nil])

      case Repo.delete(project) do
        {:ok, deleted} -> deleted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp with_staff_access(id, %StaffAccount{} = staff, fun, opts \\ [])
       when is_function(fun, 2) do
    result =
      Repo.transaction(fn ->
        with %StaffAccount{} = current_staff <- StaffAccess.lock_current(staff),
             true <-
               StaffAccount.session_claim_matches?(current_staff, staff.session_claim),
             true <- Custyard.Tenants.active?(current_staff.tenant_id),
             %Project{} = project <- lock_project_for_staff(id, current_staff) do
          case fun.(project, current_staff) do
            {:ok, value} -> value
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          _ -> Repo.rollback(:unauthorized)
        end
      end)

    if match?({:ok, _}, result) and Keyword.get(opts, :broadcast_project?, false) do
      broadcast_project_update(id)
    end

    result
  end

  defp lock_project_for_staff(id, staff) do
    query = from(p in Project, where: p.id == ^id) |> scope_to_staff(staff)

    # A no-op UPDATE obtains the row's write lock. SQLite takes its write lock
    # here, while PostgreSQL locks this row; reassignment cannot slip between
    # authorization and the following mutation.
    case Repo.update_all(query,
           set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
         ) do
      {1, _} -> Repo.get!(Project, id) |> Repo.preload(:tasks)
      {0, _} -> nil
    end
  end

  @doc """
  List all project templates.
  Templates are projects with is_template=true.
  """
  def list_templates(%Custyard.Scope{} = scope) do
    if staff_for_scope(scope) do
      from(p in Project,
        where: p.tenant_id == ^scope.tenant_id and p.is_template == true,
        order_by: [asc: p.title],
        preload: [:tasks]
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Create a new project from a template.

  Copies the template's title, description, and tasks to a new project.
  Task due dates are calculated by applying the original offset from the
  template's start_date to the new project's start_date.

  ## Parameters
    - template: The template project (must have is_template=true)
    - org_id: The organization ID for the new project
    - start_date: The start date for the new project

  ## Returns
    - `{:ok, project}` on success
    - `{:error, :not_a_template}` if the project is not a template
    - `{:error, changeset}` on validation failure
  """
  def create_from_template(%Custyard.Scope{} = scope, %Project{} = template, org_id, start_date) do
    with_access(scope, template.id, fn current, staff ->
      if staff.role == "admin" && current.tenant_id == scope.tenant_id &&
           Repo.exists?(
             from o in Custyard.Organization,
               where: o.id == ^org_id and o.tenant_id == ^scope.tenant_id
           ) do
        do_create_from_template(current, org_id, start_date)
      else
        {:error, :unauthorized}
      end
    end)
  end

  def create_from_template(%Custyard.Scope{}, nil, _, _), do: {:error, :not_a_template}

  defp do_create_from_template(%Project{is_template: true} = template, org_id, start_date) do
    template = Repo.preload(template, :tasks)

    project_attrs = %{
      title: template.title,
      tenant_id: template.tenant_id,
      description: template.description,
      start_date: start_date,
      target_completion_date: calculate_target_date(template, start_date),
      portal_visible: true,
      project_type: :customer,
      is_template: false,
      organization_id: org_id
    }

    result =
      Repo.transaction(fn ->
        with {:ok, project} <- %Project{} |> Project.changeset(project_attrs) |> Repo.insert(),
             {:ok, _tasks} <- create_tasks_from_template(project, template, start_date) do
          Repo.preload(project, :tasks) |> with_progress()
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, project} ->
        broadcast_org_project(project.organization_id, {:project_created, project.id})
        result

      error ->
        error
    end
  end

  defp do_create_from_template(%Project{is_template: false}, _org_id, _start_date) do
    {:error, :not_a_template}
  end

  # Calculate target completion date by preserving the duration from the template
  defp calculate_target_date(%Project{start_date: nil}, _new_start), do: nil
  defp calculate_target_date(%Project{target_completion_date: nil}, _new_start), do: nil

  defp calculate_target_date(
         %Project{start_date: template_start, target_completion_date: template_target},
         new_start
       ) do
    duration_days = Date.diff(template_target, template_start)
    Date.add(new_start, duration_days)
  end

  # Create tasks from template tasks, calculating due dates relative to new start date
  defp create_tasks_from_template(project, template, new_start_date) do
    template_start = template.start_date

    results =
      Enum.map(template.tasks, fn task ->
        due_at = calculate_task_due_at(task.due_at, template_start, new_start_date)

        %WorkItem{}
        |> WorkItem.changeset(%{
          title: task.title,
          state: :open,
          portal_visible: task.portal_visible,
          due_at: due_at,
          project_id: project.id
        })
        |> Repo.insert()
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, task} -> task end)}
    else
      {:error, elem(hd(errors), 1)}
    end
  end

  # Calculate new due_at by applying the same offset from template start to new start
  defp calculate_task_due_at(nil, _template_start, _new_start), do: nil
  defp calculate_task_due_at(_due_at, nil, _new_start), do: nil

  defp calculate_task_due_at(due_at, template_start, new_start) do
    # Convert template_start (Date) to DateTime for comparison
    template_start_dt = DateTime.new!(template_start, ~T[00:00:00], "Etc/UTC")
    offset_seconds = DateTime.diff(due_at, template_start_dt)

    # Apply offset to new start date
    new_start_dt = DateTime.new!(new_start, ~T[00:00:00], "Etc/UTC")
    DateTime.add(new_start_dt, offset_seconds)
  end

  @doc """
  Calculate and attach progress data to a project.

  Returns the project with its virtual `:progress` field populated:
  - `total`: total number of tasks
  - `done`: number of completed tasks
  - `percentage`: completion percentage (0-100)

  Requires tasks to be preloaded.
  """
  def with_progress(project) do
    tasks = project.tasks || []
    total = length(tasks)
    done = Enum.count(tasks, &(&1.state == :done))

    percentage =
      if total > 0 do
        round(done / total * 100)
      else
        0
      end

    # Use struct syntax to properly assign the virtual field
    %{project | progress: %{total: total, done: done, percentage: percentage}}
  end

  # Task management

  @doc """
  Create a task for a project.
  Broadcasts an update to project subscribers.
  """
  def create_task(project, attrs, opts \\ []) do
    attrs = Map.put(attrs, :project_id, project.id)

    result =
      %WorkItem{}
      |> WorkItem.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, task} ->
        Custyard.Threads.broadcast_task_change(task)
        if Keyword.get(opts, :broadcast?, true), do: broadcast_project_update(project.id)
        {:ok, task}

      error ->
        error
    end
  end

  @doc """
  Update a task's state.
  Broadcasts an update to project subscribers.
  """
  def update_task_state(%WorkItem{} = task, new_state, opts \\ []) do
    result =
      task
      |> WorkItem.state_changeset(new_state)
      |> Repo.update()

    case result do
      {:ok, task} ->
        Custyard.Threads.broadcast_task_change(task)

        if task.project_id && Keyword.get(opts, :broadcast?, true),
          do: broadcast_project_update(task.project_id)

        {:ok, task}

      error ->
        error
    end
  end

  @doc """
  Delete a task.
  Broadcasts an update to project subscribers.
  """
  def delete_task(%WorkItem{} = task, opts \\ []) do
    project_id = task.project_id

    case Repo.delete(task) do
      {:ok, _} = result ->
        Custyard.Threads.broadcast_task_change(task)

        if project_id && Keyword.get(opts, :broadcast?, true),
          do: broadcast_project_update(project_id)

        result

      error ->
        error
    end
  end

  @doc """
  Get a task by ID.
  """
  def get_task(id) do
    Repo.get(WorkItem, id)
  end

  @doc """
  Get a task by ID, scoped to a project.
  Returns nil when the task does not belong to the given project.
  """
  def get_project_task(project_id, task_id) do
    Repo.get_by(WorkItem, id: task_id, project_id: project_id)
  end

  defp broadcast_project_update(project_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "project:#{project_id}",
      {:project_updated, project_id}
    )

    case Repo.get(Project, project_id) do
      %Project{organization_id: org_id} ->
        broadcast_org_project(org_id, {:project_updated, project_id})

      nil ->
        :ok
    end
  end

  defp broadcast_org_project(nil, _event), do: :ok

  defp broadcast_org_project(org_id, event) do
    Phoenix.PubSub.broadcast(Custyard.PubSub, "projects:org:#{org_id}", event)
  end
end

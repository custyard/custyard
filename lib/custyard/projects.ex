defmodule Custyard.Projects do
  @moduledoc """
  Context for project queries and operations.
  """

  alias Custyard.{Authorization, OperatorAccess, OperatorAccount, Project, Repo, Task}
  import Ecto.Query

  @doc """
  List projects for operator view, with organization preloaded.

  ## Options

  - `:organization_id` - when set, filters to only projects in that org.
    When `nil`, returns all projects (super_admin behavior).
  """
  def list_for_operator(opts \\ []) do
    query =
      from(p in Project,
        where: p.is_template == false,
        order_by: [desc: p.inserted_at],
        preload: [:tasks, :organization]
      )

    query =
      case Keyword.get(opts, :organization_id) do
        nil -> query
        org_id -> from(p in query, where: p.organization_id == ^org_id)
      end

    query |> Repo.all() |> Enum.map(&with_progress/1)
  end

  @doc "List projects within an operator's scope, intersected with an optional org filter."
  def list_for_operator(%OperatorAccount{} = operator, opts) do
    requested_org_id = Keyword.get(opts, :organization_id)

    query =
      from(p in Project,
        where: p.is_template == false,
        order_by: [desc: p.inserted_at],
        preload: [:tasks, :organization]
      )
      |> scope_to_operator(operator)

    query =
      if is_integer(requested_org_id) do
        from(p in query, where: p.organization_id == ^requested_org_id)
      else
        query
      end

    query |> Repo.all() |> Enum.map(&with_progress/1)
  end

  defp scope_to_operator(query, %OperatorAccount{role: "super_admin"}), do: query

  defp scope_to_operator(query, %OperatorAccount{organization_id: org_id})
       when is_integer(org_id),
       do: from(p in query, where: p.organization_id == ^org_id)

  defp scope_to_operator(query, %OperatorAccount{}), do: from(p in query, where: false)

  @doc """
  List projects for a specific organization (operator view).
  """
  def list_for_organization(org_id) do
    from(p in Project,
      where: p.organization_id == ^org_id,
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
    visible_tasks = from(t in Task, where: t.portal_visible == true)

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
                tasks: from(t in Task, where: t.portal_visible == true, order_by: t.inserted_at)
              )
              |> with_progress()

            {:ok, project}
        end
    end
  end

  @doc """
  Get a project by ID (operator access).
  Returns nil if not found.
  """
  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> nil
      project -> project |> Repo.preload(:tasks) |> with_progress()
    end
  end

  @doc "Get a project only when it is within an operator's organization scope."
  def get_project_for_operator(id, %OperatorAccount{} = operator) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> get_project_for_operator(int_id, operator)
      _ -> nil
    end
  end

  def get_project_for_operator(id, %OperatorAccount{} = operator) when is_integer(id) do
    query = from(p in Project, where: p.id == ^id) |> scope_to_operator(operator)

    case Repo.one(query) do
      nil -> nil
      project -> project |> Repo.preload(:tasks) |> with_progress()
    end
  end

  def get_project_for_operator(_id, %OperatorAccount{}), do: nil

  @doc """
  Get a project by ID (operator access).
  Raises if not found.
  """
  def get_project!(id) do
    Repo.get!(Project, id)
    |> Repo.preload(:tasks)
    |> with_progress()
  end

  @doc """
  Create a project.
  """
  def create_project(attrs) do
    case %Project{} |> Project.changeset(attrs) |> Repo.insert() do
      {:ok, project} = result ->
        broadcast_org_project(project.organization_id, {:project_created, project.id})
        result

      error ->
        error
    end
  end

  @doc "Create a project with the operator's current role and assignment locked."
  def create_project_for_operator(attrs, %OperatorAccount{} = operator) do
    result =
      Repo.transaction(fn ->
        current_operator = OperatorAccess.lock_current(operator)
        changeset = Project.changeset(%Project{}, attrs)
        destination_id = Ecto.Changeset.get_field(changeset, :organization_id)

        if current_operator && Authorization.can_manage_project?(current_operator, destination_id) do
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

  @doc """
  Update a project.
  """
  def update_project(project, attrs) do
    case project |> Project.changeset(attrs) |> Repo.update() do
      {:ok, updated} = result ->
        broadcast_project_update(updated.id)

        if project.organization_id != updated.organization_id do
          broadcast_org_project(project.organization_id, {:project_updated, updated.id})
        end

        result

      error ->
        error
    end
  end

  @doc "Update an operator-managed project while holding its scoped database row lock."
  def update_project_for_operator(%Project{} = project, attrs, %OperatorAccount{} = operator) do
    case with_operator_access(project.id, operator, fn current, current_operator ->
           changeset = Project.changeset(current, attrs)
           destination_id = Ecto.Changeset.get_field(changeset, :organization_id)

           if Authorization.can_manage_project?(current_operator, current.organization_id) and
                Authorization.can_manage_project?(current_operator, destination_id) do
             case Repo.update(changeset) do
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

  @doc """
  Delete a project.
  """
  def delete_project(project) do
    case Repo.delete(project) do
      {:ok, deleted} = result ->
        broadcast_org_project(deleted.organization_id, {:project_deleted, deleted.id})
        result

      error ->
        error
    end
  end

  @doc "Delete an operator-managed project only while its scoped row is locked."
  def delete_project_for_operator(%Project{} = project, %OperatorAccount{} = operator) do
    case with_operator_access(project.id, operator, fn current, current_operator ->
           if Authorization.can_manage_project?(current_operator, current.organization_id) do
             Repo.delete(current)
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

  @doc "Run a project mutation while its current operator scope is locked."
  def with_operator_access(id, %OperatorAccount{} = operator, fun, opts \\ [])
      when is_function(fun, 2) do
    result =
      Repo.transaction(fn ->
        with %OperatorAccount{} = current_operator <- OperatorAccess.lock_current(operator),
             %Project{} = project <- lock_project_for_operator(id, current_operator) do
          case fun.(project, current_operator) do
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

  defp lock_project_for_operator(id, operator) do
    query = from(p in Project, where: p.id == ^id) |> scope_to_operator(operator)

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
  def list_templates do
    from(p in Project,
      where: p.is_template == true,
      order_by: [asc: p.title],
      preload: [:tasks]
    )
    |> Repo.all()
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
  def create_from_template(%Project{is_template: true} = template, org_id, start_date) do
    template = Repo.preload(template, :tasks)

    project_attrs = %{
      title: template.title,
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

  def create_from_template(%Project{is_template: false}, _org_id, _start_date) do
    {:error, :not_a_template}
  end

  def create_from_template(nil, _org_id, _start_date) do
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

        %Task{}
        |> Task.changeset(%{
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
      %Task{}
      |> Task.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, task} ->
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
  def update_task_state(%Task{} = task, new_state, opts \\ []) do
    result =
      task
      |> Task.state_changeset(new_state)
      |> Repo.update()

    case result do
      {:ok, task} ->
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
  def delete_task(%Task{} = task, opts \\ []) do
    project_id = task.project_id

    case Repo.delete(task) do
      {:ok, _} = result ->
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
    Repo.get(Task, id)
  end

  @doc """
  Get a task by ID, scoped to a project.
  Returns nil when the task does not belong to the given project.
  """
  def get_project_task(project_id, task_id) do
    Repo.get_by(Task, id: task_id, project_id: project_id)
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

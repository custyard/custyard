defmodule Custyard.Projects do
  @moduledoc """
  Context for project queries and operations.
  """

  alias Custyard.{Repo, Project, Task}
  import Ecto.Query

  @doc """
  List portal-visible projects for an organization.
  """
  def list_portal_visible(org_id) do
    from(p in Project,
      where: p.organization_id == ^org_id,
      where: p.portal_visible == true,
      order_by: [desc: p.inserted_at],
      preload: [:tasks]
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
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a project.
  """
  def update_project(project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a project.
  """
  def delete_project(project) do
    Repo.delete(project)
  end

  defp with_progress(project) do
    tasks = project.tasks || []
    total = length(tasks)
    done = Enum.count(tasks, &(&1.state == :done))

    progress =
      if total > 0 do
        round(done / total * 100)
      else
        0
      end

    Map.put(project, :progress, %{total: total, done: done, percentage: progress})
  end
end

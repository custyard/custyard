defmodule Custyard.Repo.Migrations.AddProjectIdToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :project_id, references(:projects, on_delete: :nilify_all)
    end

    create index(:tasks, [:project_id])
  end
end

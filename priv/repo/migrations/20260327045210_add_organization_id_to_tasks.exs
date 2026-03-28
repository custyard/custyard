defmodule Custyard.Repo.Migrations.AddOrganizationIdToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Direct organization reference for scoping
      # Tasks with project_id or conversation_id can derive org from those,
      # but having org_id allows direct queries and prevents orphaned tasks
      add :organization_id, references(:organizations, on_delete: :nilify_all)
    end

    create index(:tasks, [:organization_id])
  end
end

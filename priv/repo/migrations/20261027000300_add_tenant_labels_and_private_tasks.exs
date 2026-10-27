defmodule Custyard.Repo.Migrations.AddTenantLabelsAndPrivateTasks do
  use Ecto.Migration

  def up do
    create table(:labels) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :normalized_name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:labels, [:tenant_id, :normalized_name])

    create table(:conversation_labels, primary_key: false) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), primary_key: true
      add :label_id, references(:labels, on_delete: :delete_all), primary_key: true
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:conversation_labels, [:label_id])
    rebuild_tasks(false)
    create index(:tasks, [:state, :due_at, :conversation_id])
  end

  def down do
    drop table(:conversation_labels)
    drop table(:labels)
    rebuild_tasks(true)
  end

  # SQLite does not support ALTER COLUMN. No table references tasks, so a
  # copy/rename preserves existing sharing decisions while changing the SQL
  # default for future rows, including inserts outside Ecto.
  defp rebuild_tasks(visible_default) do
    # A normal helper table is transaction-local in effect and also works on
    # libSQL versions that do not support CREATE TEMP TABLE through Hrana.
    execute "CREATE TABLE custyard_task_sequence (seq INTEGER)"

    execute "INSERT INTO custyard_task_sequence SELECT seq FROM sqlite_sequence WHERE name = 'tasks'"

    create table(:tasks_new_default) do
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :organization_id, references(:organizations, on_delete: :nilify_all)
      add :title, :string, null: false
      add :state, :string, default: "open", null: false
      add :portal_visible, :boolean, default: visible_default, null: false
      add :due_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    execute """
    INSERT INTO tasks_new_default
      (id, conversation_id, project_id, organization_id, title, state, portal_visible, due_at, inserted_at, updated_at)
    SELECT id, conversation_id, project_id, organization_id, title, state, portal_visible, due_at, inserted_at, updated_at
    FROM tasks
    """

    drop table(:tasks)
    rename table(:tasks_new_default), to: table(:tasks)
    execute "DELETE FROM sqlite_sequence WHERE name = 'tasks'"

    execute "INSERT INTO sqlite_sequence(name,seq) SELECT 'tasks', COALESCE(MAX(seq),0) FROM custyard_task_sequence"

    execute "DROP TABLE custyard_task_sequence"
    create index(:tasks, [:conversation_id])
    create index(:tasks, [:project_id])
    create index(:tasks, [:organization_id])
  end
end

defmodule Custyard.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :title, :string, null: false
      add :state, :string, default: "open", null: false
      add :portal_visible, :boolean, default: true, null: false
      add :due_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:conversation_id])
  end
end

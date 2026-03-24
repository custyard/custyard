defmodule Custyard.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :title, :string, null: false
      add :description, :text
      add :start_date, :date
      add :target_completion_date, :date
      add :portal_visible, :boolean, default: true, null: false

      add :organization_id, references(:organizations, on_delete: :nilify_all)
      add :conversation_id, references(:conversations, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:organization_id])
    create index(:projects, [:conversation_id])
  end
end

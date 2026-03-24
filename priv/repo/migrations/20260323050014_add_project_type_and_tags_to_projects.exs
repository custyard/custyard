defmodule Custyard.Repo.Migrations.AddProjectTypeAndTagsToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :project_type, :string, default: "customer", null: false
      # SQLite stores arrays as JSON, so we use text type
      add :tags, :text, default: "[]"
    end

    create index(:projects, [:project_type])
  end
end

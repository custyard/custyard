defmodule Custyard.Repo.Migrations.CreateIntakeSources do
  use Ecto.Migration

  def change do
    create table(:intake_sources) do
      # Public URL segment identifying the intake CTA; format-locked in the schema
      add :key, :string, null: false
      add :name, :string, null: false
      # Presentation mode: "active" (form-first) or "passive" (info page)
      add :mode, :string, null: false, default: "active"
      add :headline, :string
      add :intro_copy, :string
      # Q&A list for passive pages. SQLite stores arrays as JSON, so we use
      # text type (same as projects.tags)
      add :questions, :text, default: "[]"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:intake_sources, [:key])
  end
end

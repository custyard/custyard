defmodule Custyard.Repo.Migrations.AddIsTemplateToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :is_template, :boolean, default: false, null: false
    end

    # Templates should not have an organization and should not be portal visible
    create index(:projects, [:is_template], where: "is_template = true")
  end
end

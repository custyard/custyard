defmodule Custyard.Repo.Migrations.AddLinkToIntakeSources do
  use Ecto.Migration

  def change do
    alter table(:intake_sources) do
      # Optional per-source branding link back to the operator's product,
      # rendered on prospect surfaces only when BOTH fields are set.
      # link_url is format-locked to http/https in the schema — it renders
      # verbatim as an anchor href on public pages.
      add :link_title, :string
      add :link_url, :string
    end
  end
end

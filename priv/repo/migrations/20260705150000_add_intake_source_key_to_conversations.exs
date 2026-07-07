defmodule Custyard.Repo.Migrations.AddIntakeSourceKeyToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # CTA provenance: which public intake source (by key string, not FK —
      # provenance must survive intake-source rename/delete) created this
      # conversation. Set once at creation, never operator-editable.
      add :intake_source_key, :string
    end

    create index(:conversations, [:intake_source_key])
  end
end

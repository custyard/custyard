defmodule Custyard.Repo.Migrations.ChangeContactsEmailUniqueIndexToComposite do
  use Ecto.Migration

  def change do
    drop unique_index(:contacts, [:email])
    create unique_index(:contacts, [:email, :organization_id])
  end
end

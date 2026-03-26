defmodule Custyard.Repo.Migrations.UpdateContactUniqueness do
  use Ecto.Migration

  def change do
    # Drop the old unique index on email alone
    drop_if_exists index(:contacts, [:email], name: :contacts_email_index)
    drop_if_exists unique_index(:contacts, [:email], name: :contacts_email_index)

    # Create composite unique index: email + organization_id
    create_if_not_exists unique_index(:contacts, [:email, :organization_id])
  end
end

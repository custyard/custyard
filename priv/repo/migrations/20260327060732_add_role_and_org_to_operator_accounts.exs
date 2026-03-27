defmodule Custyard.Repo.Migrations.AddRoleAndOrgToOperatorAccounts do
  use Ecto.Migration

  def change do
    alter table(:operator_accounts) do
      add :role, :string, default: "super_admin", null: false
      add :organization_id, references(:organizations, on_delete: :nilify_all)
    end

    create index(:operator_accounts, [:organization_id])
    create index(:operator_accounts, [:role])
  end
end

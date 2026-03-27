defmodule Custyard.Repo.Migrations.AddSingletonConstraintToSettings do
  use Ecto.Migration

  @moduledoc """
  Adds a database-enforced singleton constraint to the settings table.

  The settings table should only ever have one row. Previously this was
  enforced only at the application level (fixed id=1 in create_defaults).
  This migration adds a unique constraint to prevent accidental duplicates.
  """

  def change do
    # Add a singleton column with a constant value and unique constraint
    # This ensures only one row can exist in the settings table
    alter table(:settings) do
      add :singleton, :boolean, null: false, default: true
    end

    create unique_index(:settings, [:singleton])
  end
end

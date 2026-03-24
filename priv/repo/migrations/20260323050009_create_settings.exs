defmodule Custyard.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :score_weights, :map, null: false
      add :neglect_thresholds, :map, null: false

      timestamps(type: :utc_datetime)
    end
  end
end

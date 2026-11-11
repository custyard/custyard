defmodule Custyard.Repo.Migrations.CreateTenantBaseline do
  use Ecto.Migration

  @external_resource Path.expand("../schema.sql", __DIR__)
  @statements @external_resource
              |> File.read!()
              |> String.split(";")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

  def up do
    Enum.each(@statements, &execute/1)
  end

  def down do
    raise "This baseline is reset-only; recreate the database explicitly"
  end
end

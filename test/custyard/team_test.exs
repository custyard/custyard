defmodule Custyard.TeamTest do
  use Custyard.DataCase, async: true

  alias Custyard.Team

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with name" do
      changeset = Team.changeset(%Team{}, %{name: "Support Team"})
      assert changeset.valid?
    end

    test "requires name" do
      changeset = Team.changeset(%Team{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "enforces unique name" do
      insert_team(name: "Support Team")

      {:error, changeset} =
        %Team{}
        |> Team.changeset(%{name: "Support Team"})
        |> Repo.insert()

      assert errors_on(changeset)[:name]
    end

    test "accepts organization_id" do
      org = insert_organization()

      {:ok, team} =
        %Team{}
        |> Team.changeset(%{name: "Org Team", organization_id: org.id})
        |> Repo.insert()

      assert team.organization_id == org.id
    end
  end
end

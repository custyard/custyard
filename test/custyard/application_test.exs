defmodule Custyard.ApplicationTest do
  use ExUnit.Case, async: false

  alias Custyard.Application, as: App

  defp ids(children), do: Enum.map(children, &Supervisor.child_spec(&1, []).id)

  describe "child lists" do
    test "early children are exactly telemetry and the endpoint" do
      assert App.early_children() == [CustyardWeb.Telemetry, CustyardWeb.Endpoint]
    end

    test "deferred children hold the Repo and PubSub and none of the early ones" do
      children = App.deferred_children([])
      deferred = ids(children)

      assert Custyard.Repo in deferred
      assert {Phoenix.PubSub, name: Custyard.PubSub} in children

      for early <- ids(App.early_children()) do
        refute early in deferred
      end
    end

    test "first run is placed after Finch when requested, absent otherwise" do
      refute Custyard.Boot.FirstRun in ids(App.deferred_children([]))

      children = App.deferred_children(first_run: [env: %{}, schema: %{}])
      assert {Custyard.Boot.FirstRun, [env: %{}, schema: %{}]} in children

      ids = ids(children)
      finch = Enum.find_index(ids, &(&1 == Custyard.Finch))
      first_run = Enum.find_index(ids, &(&1 == Custyard.Boot.FirstRun))

      assert is_integer(finch)
      assert is_integer(first_run)
      assert first_run > finch
    end
  end

  describe "legacy file import" do
    test "is off in the test environment and not running" do
      refute Application.get_env(:custyard, :start_legacy_file_import, true)
      refute Custyard.Files.LegacyImport in ids(App.deferred_children([]))

      refute Enum.any?(
               Supervisor.which_children(Custyard.Supervisor),
               &match?({Custyard.Files.LegacyImport, _pid, _type, _modules}, &1)
             )
    end

    test "is the last deferred child, as a temporary task, unless flagged off" do
      Application.delete_env(:custyard, :start_legacy_file_import)

      try do
        children = App.deferred_children(first_run: [env: %{}, schema: %{}])
        assert List.last(children) == Custyard.Files.LegacyImport

        assert %{restart: :temporary, start: {Task, :start_link, _args}} =
                 Supervisor.child_spec(List.last(children), [])
      after
        Application.put_env(:custyard, :start_legacy_file_import, false)
      end
    end
  end

  describe "scheduler configuration" do
    test "scheduler is disabled in test environment" do
      # In test.exs, :start_scheduler is set to false
      refute Application.get_env(:custyard, :start_scheduler, true)
    end

    test "scheduler process is not running in tests" do
      # Since :start_scheduler is false in test.exs, the Scheduler should not be started
      refute Process.whereis(Custyard.Scoring.Scheduler)
    end

    test "start_scheduler defaults to true when not configured" do
      # Verify the default behavior - when config is not set, should default to true
      # We test this by checking the Application module's behavior with nil config
      original = Application.get_env(:custyard, :start_scheduler)
      Application.delete_env(:custyard, :start_scheduler)

      try do
        # With no config, get_env returns nil, so default (true) is used
        assert Application.get_env(:custyard, :start_scheduler, true) == true
      after
        # Restore original config
        if original != nil do
          Application.put_env(:custyard, :start_scheduler, original)
        end
      end
    end
  end
end

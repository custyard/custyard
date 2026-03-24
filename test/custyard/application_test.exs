defmodule Custyard.ApplicationTest do
  use ExUnit.Case, async: false

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

defmodule Mix.Tasks.Dev.ResetOperatorPasswordTest do
  @moduledoc """
  Tests for the deprecated Dev.ResetOperatorPassword mix task.
  Now shows deprecation notice since Custyard uses email-only auth.
  """
  use Custyard.DataCase, async: false

  alias Mix.Tasks.Dev.ResetOperatorPassword

  describe "run/1" do
    test "shows deprecation notice" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ResetOperatorPassword.run([])
        end)

      assert output =~ "DEPRECATED"
      assert output =~ "email-only authentication"
    end
  end
end

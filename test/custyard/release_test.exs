defmodule Custyard.ReleaseTest do
  use Custyard.DataCase, async: false

  alias Custyard.{OperatorAccount, Release}

  describe "setup_operator/1" do
    test "stores the email lowercased and is a no-op when it already exists" do
      assert Release.setup_operator(" Ops@Example.COM ") == :ok
      assert Release.setup_operator("OPS@example.com") == :ok

      assert [%OperatorAccount{email: "ops@example.com", role: "super_admin"}] =
               Repo.all(OperatorAccount)
    end
  end
end

defmodule Custyard.Boot.BuildTest do
  use ExUnit.Case, async: true

  alias Custyard.Boot.Build

  test "describe/0 reports the mix.exs version with git_sha and built_at" do
    assert %{version: version, git_sha: git_sha, built_at: built_at} = Build.describe()
    assert version == Mix.Project.config()[:version]
    assert is_binary(git_sha) and git_sha != ""
    assert is_binary(built_at) and built_at != ""
  end

  test "passes through build values set at release time" do
    assert %{git_sha: "7f3a2c1", built_at: "2026-11-03T14:02:00Z"} =
             Build.describe(git_sha: "7f3a2c1", built_at: "2026-11-03T14:02:00Z")
  end

  test "absent or blank build values read unknown" do
    assert %{git_sha: "unknown", built_at: "unknown"} = Build.describe([])
    assert %{git_sha: "unknown", built_at: "unknown"} = Build.describe(git_sha: "", built_at: nil)
  end
end

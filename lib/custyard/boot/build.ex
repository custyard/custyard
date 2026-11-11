defmodule Custyard.Boot.Build do
  @moduledoc """
  Identity of the running release: application version, git SHA and build
  time.

  Printed on every boot report and doctor card so a deploy that did not pick
  up a new image is visible (docs/backlog/1103-first-run-experience.md). The
  SHA and time are baked in when the release is built, from `GIT_SHA` and
  `BUILD_TIME` (config/config.exs); outside a CI image build both read
  `"unknown"`.
  """

  @unknown "unknown"

  @type t :: %{version: String.t(), git_sha: String.t(), built_at: String.t()}

  @doc """
  Describes the running build. Never raises; absent or blank fields read
  `"unknown"`.
  """
  @spec describe(keyword()) :: t()
  def describe(build \\ Application.get_env(:custyard, :build, [])) do
    %{
      version: version(),
      git_sha: field(build, :git_sha),
      built_at: field(build, :built_at)
    }
  end

  defp version do
    case Application.spec(:custyard, :vsn) do
      nil -> @unknown
      vsn -> to_string(vsn)
    end
  end

  defp field(build, key) do
    case Keyword.get(build, key) do
      value when is_binary(value) and value != "" -> value
      _ -> @unknown
    end
  end
end

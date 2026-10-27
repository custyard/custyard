defmodule Custyard.LettermintRuntimeConfigTest do
  use ExUnit.Case, async: false
  alias Config.Reader
  alias Custyard.Lettermint.{DisabledClient, HttpClient}
  alias Custyard.Mailer
  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @keys ~w(MAIL_ADAPTER SECRET_KEY_BASE LETTERMINT_PROJECT_TOKEN LETTERMINT_TEAM_TOKEN LETTERMINT_API_KEY LETTERMINT_API_URL DATABASE_URL DATABASE_PATH)

  setup do
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)
    System.put_env("MAIL_ADAPTER", "lettermint")
    System.put_env("SECRET_KEY_BASE", String.duplicate("test-only-key-", 8))

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "project and Team tokens configure separate APIs" do
    System.put_env("LETTERMINT_PROJECT_TOKEN", "project-token")
    System.put_env("LETTERMINT_TEAM_TOKEN", "team-token")
    config = Reader.read!(@runtime, env: :prod)[:custyard]
    assert config[Mailer][:api_token] == "project-token"
    assert config[:lettermint][:team_token] == "team-token"
    refute Keyword.has_key?(config[:lettermint], :api_key)
    assert config[:lettermint][:client] == HttpClient
  end

  test "legacy token only configures sending and production management stays disabled" do
    System.put_env("LETTERMINT_API_KEY", "legacy-project-token")
    config = Reader.read!(@runtime, env: :prod)[:custyard]
    assert config[Mailer][:api_token] == "legacy-project-token"
    assert config[:lettermint][:client] == DisabledClient
    refute config[:lettermint_configured]
    assert {:error, :not_configured} = DisabledClient.create_route(%{})

    assert {:error, :not_configured} =
             DisabledClient.verify_inbound_domain("real-route")
  end

  test "explicit project token takes precedence over the legacy sending alias" do
    System.put_env("LETTERMINT_API_KEY", "legacy-project-token")
    System.put_env("LETTERMINT_PROJECT_TOKEN", "new-project-token")
    config = Reader.read!(@runtime, env: :prod)[:custyard]
    assert config[Mailer][:api_token] == "new-project-token"
  end
end

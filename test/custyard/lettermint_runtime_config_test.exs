defmodule Custyard.LettermintRuntimeConfigTest do
  use ExUnit.Case, async: false
  alias Config.Reader
  alias Custyard.Lettermint.HttpClient
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

  test "system sending config never bootstraps tenant provider access" do
    System.put_env("LETTERMINT_PROJECT_TOKEN", "system-project-token")
    System.put_env("LETTERMINT_TEAM_TOKEN", "unused-global-management-token")
    config = Reader.read!(@runtime, env: :prod)[:custyard]
    assert config[Mailer][:api_token] == "system-project-token"
    assert config[:lettermint][:client] == HttpClient
    refute Keyword.has_key?(config[:lettermint], :team_token)
    refute Keyword.has_key?(config[:lettermint], :api_key)
  end

  test "removed sending aliases do not configure credentials" do
    System.put_env("LETTERMINT_API_KEY", "unused-token")
    config = Reader.read!(@runtime, env: :prod)[:custyard]
    assert is_nil(config[Mailer][:api_token])
    refute Keyword.has_key?(config[:lettermint], :team_token)
  end

  test "SMTP installations keep the HTTP client available for tenant Lettermint mail" do
    System.put_env("MAIL_ADAPTER", "smtp")
    config = Reader.read!(@runtime, env: :prod)
    assert config[:custyard][Mailer][:adapter] == Swoosh.Adapters.SMTP
    assert config[:swoosh][:api_client] == Swoosh.ApiClient.Finch
    assert config[:swoosh][:finch_name] == Custyard.Finch
  end
end

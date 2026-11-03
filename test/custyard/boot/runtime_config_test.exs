defmodule Custyard.Boot.RuntimeConfigTest do
  # Mutates process-global env vars and reads config/runtime.exs: sequential only.
  use ExUnit.Case, async: false

  alias Custyard.Boot.Env

  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)
  @env_vars Env.known_names() ++ ~w(FLY_APP_NAME BUNNY_DATABASE_URL BUNNY_DATABASE_AUTH_TOKEN)

  @minimal %{
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "custyard.example.com",
    "MAIL_ADAPTER" => "lettermint",
    "LETTERMINT_PROJECT_TOKEN" => "lm_project_token",
    "OPERATOR_EMAIL" => "ops@example.com"
  }

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(@env_vars, &System.delete_env/1)
    :ok
  end

  defp read_prod!(vars) do
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)
    Config.Reader.read!(@runtime_config, env: :prod)
  end

  test "a zero environment reads without raising and can serve the doctor card" do
    config = read_prod!(%{})
    custyard = config[:custyard]

    assert %Env{verdict: :unconfigured} = custyard[:boot_env]

    endpoint = custyard[CustyardWeb.Endpoint]
    assert {:ok, secret} = Base.decode64(endpoint[:secret_key_base])
    assert byte_size(secret) == 64
    assert endpoint[:url][:host] == "localhost"
    assert endpoint[:http][:port] == 4000

    assert custyard[Custyard.Repo][:database] == "/data/custyard.db"
    assert custyard[Custyard.Repo][:journal_mode] == :wal
    assert custyard[Custyard.Mailer] == nil
    assert config[:swoosh] == nil
    assert custyard[:credential_keys] == [current: nil, previous: []]
    assert custyard[:email_enabled] == false
    assert custyard[:trust_proxy_headers] == false
    assert custyard[:upload_dir] == "/data/uploads"
    assert custyard[:attachment_dir] == "/data/attachments"
  end

  test "a complete environment configures everything from the parsed settings" do
    config = read_prod!(Map.merge(@minimal, %{"PORT" => "8080", "POOL_SIZE" => "4"}))
    custyard = config[:custyard]

    assert %Env{verdict: :configured} = custyard[:boot_env]

    endpoint = custyard[CustyardWeb.Endpoint]
    assert endpoint[:secret_key_base] == @minimal["SECRET_KEY_BASE"]
    assert endpoint[:url] == [host: "custyard.example.com", port: 443, scheme: "https"]
    assert endpoint[:http][:port] == 8080
    assert is_binary(endpoint[:live_view][:signing_salt])

    assert custyard[Custyard.Mailer][:adapter] == Swoosh.Adapters.Lettermint
    assert custyard[Custyard.Mailer][:api_token] == "lm_project_token"
    assert config[:swoosh][:api_client] == Swoosh.ApiClient.Finch

    assert custyard[Custyard.Repo][:pool_size] == 4
    assert byte_size(custyard[:credential_keys][:current]) == 32
    assert custyard[:email_enabled] == true
    assert custyard[:operator_email] == "ops@example.com"
    assert custyard[:email_from_name] == "Custyard"
    assert custyard[:email_from_address] == "noreply@custyard.example.com"
  end

  test "malformed values are problems, never raises" do
    config =
      read_prod!(%{
        "MAIL_ADAPTER" => "\"lettermint\"",
        "CREDENTIAL_ENCRYPTION_KEY" => "not-base64\n",
        "IMAP_ENABLED" => "true",
        "ACKNOWLEDGMENTS_ENABLED" => "yes",
        "ACKNOWLEDGMENTS_PREFETCH" => "0",
        "DATABASE_PATH" => "relative/custyard.db",
        "PORT" => "eighty"
      })

    custyard = config[:custyard]
    env = custyard[:boot_env]

    assert env.verdict == :unconfigured
    variables = Enum.map(env.problems, & &1.variable)

    for name <-
          ~w(MAIL_ADAPTER CREDENTIAL_ENCRYPTION_KEY IMAP_ENABLED ACKNOWLEDGMENTS_ENABLED ACKNOWLEDGMENTS_PREFETCH DATABASE_PATH PORT) do
      assert name in variables, "#{name} should be a problem"
    end

    assert custyard[:legacy_imap_enabled] == true
    assert custyard[:acknowledgments][:enabled] == true
    assert custyard[:acknowledgments][:prefetch] == 1
    assert custyard[Custyard.Repo] == nil
    assert custyard[Custyard.Mailer] == nil
    assert custyard[CustyardWeb.Endpoint][:http][:port] == 4000
  end

  test "a postgres:// URL on the SQLite/libSQL build leaves the Repo unconfigured" do
    config = read_prod!(Map.put(@minimal, "DATABASE_URL", "postgres://db.internal/custyard"))

    assert config[:custyard][:boot_env].verdict == :configured
    assert config[:custyard][Custyard.Repo] == nil
  end

  test "Fly sets proxy trust and the PHX_HOST fallback" do
    config =
      read_prod!(Map.merge(Map.delete(@minimal, "PHX_HOST"), %{"FLY_APP_NAME" => "custyard-eu"}))

    assert config[:custyard][:trust_proxy_headers] == true
    assert config[:custyard][CustyardWeb.Endpoint][:url][:host] == "custyard-eu.fly.dev"
    assert config[:custyard][:boot_env].verdict == :configured
  end

  test "dev and test reads do not store a boot verdict" do
    for env <- [:dev, :test] do
      config = Config.Reader.read!(@runtime_config, env: env)
      assert config[:custyard][:boot_env] == nil
    end
  end
end

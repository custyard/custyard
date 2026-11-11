defmodule Custyard.Turso.RuntimeConfigTest do
  # Mutates process-global env vars and reads config/runtime.exs: sequential only.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @config Path.expand("../../../config/config.exs", __DIR__)
  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)
  @database_vars ~w(DATABASE_PROVIDER DATABASE_URL TURSO_AUTH_TOKEN DATABASE_PATH BUNNY_DATABASE_URL BUNNY_DATABASE_AUTH_TOKEN)
  @env_vars @database_vars ++ ~w(MAIL_ADAPTER SECRET_KEY_BASE PHX_HOST CREDENTIAL_ENCRYPTION_KEY)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(@database_vars, &System.delete_env/1)
    # The settings prod refuses to boot without, so that a database problem
    # is the only thing between these tests and a configured verdict.
    System.put_env("MAIL_ADAPTER", "local")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    System.put_env("PHX_HOST", "custyard.example.com")
    System.put_env("CREDENTIAL_ENCRYPTION_KEY", Base.encode64(String.duplicate("c", 32)))
    :ok
  end

  # The mail and Lettermint warnings a prod read prints are expected here.
  defp prod_config do
    {config, _warnings} =
      with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: :prod) end)

    config[:custyard]
  end

  defp prod_repo_config, do: prod_config()[Custyard.Repo]

  # config/runtime.exs never raises: the boot verdict carries the problem
  # (Custyard.Boot.Env) and the Repo is left unconfigured, so nothing can
  # start on a database nobody chose. Returns the problem on `variable`.
  defp refused(variable) do
    config = prod_config()
    env = config[:boot_env]
    assert env.verdict == :unconfigured
    assert config[Custyard.Repo] == nil
    assert [%{variable: ^variable} = problem] = env.problems
    problem
  end

  test "a libsql:// DATABASE_URL with a token configures Turso, not a file" do
    System.put_env("DATABASE_URL", "libsql://custyard-acme.turso.io")
    System.put_env("TURSO_AUTH_TOKEN", "token")

    config = prod_repo_config()
    assert config[:turso_url] == "libsql://custyard-acme.turso.io"
    assert config[:turso_auth_token] == "token"
    refute Keyword.has_key?(config, :database)
  end

  # A release merges config.exs (with prod.exs), read at build time, with
  # runtime.exs, read at boot. A SQLite path from the first would survive into
  # the Turso config and send Storage and export_sqlite after the old file.
  test "the release config on Turso keeps no SQLite path" do
    System.put_env("DATABASE_URL", "libsql://custyard-acme.turso.io")
    System.put_env("TURSO_AUTH_TOKEN", "token")

    {runtime, _warnings} =
      with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: :prod) end)

    release = Config.Reader.merge(Config.Reader.read!(@config, env: :prod), runtime)
    config = release[:custyard][Custyard.Repo]

    assert config[:turso_url] == "libsql://custyard-acme.turso.io"
    assert config[:database] == nil
  end

  # The boot verdict carries the problem (Custyard.Boot.Env); the Repo is
  # still configured so the doctor report can describe the choice.
  test "a libsql:// DATABASE_URL without a token is a boot problem, not a raise" do
    for token <- [nil, ""] do
      if token,
        do: System.put_env("TURSO_AUTH_TOKEN", token),
        else: System.delete_env("TURSO_AUTH_TOKEN")

      System.put_env("DATABASE_URL", "libsql://custyard-acme.turso.io")

      {config, _warnings} =
        with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: :prod) end)

      env = config[:custyard][:boot_env]
      assert env.verdict == :unconfigured
      assert Enum.any?(env.problems, &(&1.variable == "TURSO_AUTH_TOKEN" and &1.kind == :missing))
      assert config[:custyard][Custyard.Repo][:turso_url] == "libsql://custyard-acme.turso.io"
      assert config[:custyard][Custyard.Repo][:turso_auth_token] == nil
    end
  end

  test "a libSQL server on plain HTTP may run without a token" do
    System.put_env("DATABASE_URL", "libsql://sqld.internal:8080?tls=0")

    config = prod_repo_config()
    assert config[:turso_url] == "libsql://sqld.internal:8080?tls=0"
    assert config[:turso_auth_token] == nil
  end

  test "without DATABASE_URL the database is the SQLite file on the volume" do
    config = prod_repo_config()
    assert config[:database] == "/data/custyard.db"
    refute Keyword.has_key?(config, :turso_url)
  end

  test "Bunny aliases select v2 provider without a SQLite fallback" do
    System.put_env("BUNNY_DATABASE_URL", "https://test.lite.bunnydb.net")
    System.put_env("BUNNY_DATABASE_AUTH_TOKEN", "private-test-token")
    assert prod_config()[:boot_env].verdict == :configured
    config = prod_repo_config()
    assert config[:turso_provider] == :bunny
    assert config[:turso_url] == "https://test.lite.bunnydb.net"
    assert config[:turso_auth_token] == "private-test-token"
    refute Keyword.has_key?(config, :database)
  end

  test "explicit Bunny provider accepts existing names and identical aliases" do
    System.put_env("DATABASE_PROVIDER", "bunny")
    System.put_env("DATABASE_URL", "libsql://test.lite.bunnydb.net")
    System.put_env("TURSO_AUTH_TOKEN", "private-test-token")
    assert prod_repo_config()[:turso_provider] == :bunny
    System.put_env("BUNNY_DATABASE_URL", "libsql://test.lite.bunnydb.net")
    System.put_env("BUNNY_DATABASE_AUTH_TOKEN", "private-test-token")
    assert prod_repo_config()[:turso_provider] == :bunny
  end

  test "Bunny settings never silently start a local database" do
    System.put_env("DATABASE_PROVIDER", "bunny")
    assert refused("BUNNY_DATABASE_URL").kind == :missing

    # A URL without its token still describes the choice for the doctor
    # report; the verdict keeps the Repo from ever starting on it.
    for token <- [nil, ""] do
      System.put_env("BUNNY_DATABASE_URL", "https://test.lite.bunnydb.net")
      if token, do: System.put_env("BUNNY_DATABASE_AUTH_TOKEN", token)
      config = prod_config()
      env = config[:boot_env]
      assert env.verdict == :unconfigured
      assert [%{variable: "BUNNY_DATABASE_AUTH_TOKEN", kind: :missing}] = env.problems

      assert config[Custyard.Repo][:turso_provider] == :bunny
      assert config[Custyard.Repo][:turso_auth_token] == nil
      refute Keyword.has_key?(config[Custyard.Repo], :database)
    end
  end

  test "conflicting aliases reject configuration without exposing values" do
    System.put_env("BUNNY_DATABASE_URL", "https://test.lite.bunnydb.net")
    System.put_env("BUNNY_DATABASE_AUTH_TOKEN", "private-test-token")
    System.put_env("DATABASE_URL", "libsql://other.invalid")
    problem = refused("BUNNY_DATABASE_URL")
    assert problem.detail =~ "conflicts with DATABASE_URL"
    refute problem.detail =~ "other.invalid"
    System.delete_env("DATABASE_URL")
    System.put_env("TURSO_AUTH_TOKEN", "another-private-token")

    problem = refused("BUNNY_DATABASE_AUTH_TOKEN")
    assert problem.detail =~ "conflicts with TURSO_AUTH_TOKEN"
    refute problem.detail =~ "private-token"
  end

  test "provider choice rejects stale settings and unsafe Bunny URLs" do
    System.put_env("DATABASE_PROVIDER", "turso")
    System.put_env("BUNNY_DATABASE_URL", "https://test.lite.bunnydb.net")
    assert refused("DATABASE_PROVIDER").detail =~ "conflicts"
    System.put_env("DATABASE_PROVIDER", "bunny")
    System.put_env("BUNNY_DATABASE_AUTH_TOKEN", "test-token")

    for url <- [
          "http://test.invalid",
          "libsql://test.invalid?tls=0",
          "https://user:pass@test.invalid"
        ] do
      System.put_env("BUNNY_DATABASE_URL", url)
      problem = refused("BUNNY_DATABASE_URL")
      assert problem.detail =~ "Bunny Database URL"
      refute problem.detail =~ "test.invalid"
    end
  end

  test "explicit remote provider requires a URL and tokens cannot select SQLite" do
    System.put_env("DATABASE_PROVIDER", "turso")
    assert refused("DATABASE_URL").kind == :missing
    System.delete_env("DATABASE_PROVIDER")
    System.put_env("TURSO_AUTH_TOKEN", "orphan-token")
    assert refused("DATABASE_URL").detail =~ "TURSO_AUTH_TOKEN is set"
    System.put_env("DATABASE_PROVIDER", "sqlite")
    assert refused("DATABASE_PROVIDER").detail =~ "conflicts"
  end

  test "an unknown DATABASE_PROVIDER is refused without echoing its value" do
    System.put_env("DATABASE_PROVIDER", "private-invalid-provider")
    problem = refused("DATABASE_PROVIDER")
    assert problem.kind == :unsupported
    refute problem.detail =~ "private-invalid-provider"
  end
end

defmodule Custyard.Turso.RuntimeConfigTest do
  # Mutates process-global env vars and reads config/runtime.exs: sequential only.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @config Path.expand("../../../config/config.exs", __DIR__)
  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)
  @env_vars ~w(DATABASE_URL TURSO_AUTH_TOKEN DATABASE_PATH MAIL_ADAPTER SECRET_KEY_BASE)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(~w(DATABASE_URL TURSO_AUTH_TOKEN DATABASE_PATH), &System.delete_env/1)
    # The settings prod refuses to boot without.
    System.put_env("MAIL_ADAPTER", "local")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    :ok
  end

  # The mail and Lettermint warnings a prod read prints are expected here.
  defp prod_repo_config do
    {config, _warnings} =
      with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: :prod) end)

    config[:custyard][Custyard.Repo]
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

  test "a libsql:// DATABASE_URL without a token refuses to boot" do
    System.put_env("DATABASE_URL", "libsql://custyard-acme.turso.io")

    assert_raise RuntimeError, ~r/TURSO_AUTH_TOKEN is not set/, &prod_repo_config/0

    System.put_env("TURSO_AUTH_TOKEN", "")
    assert_raise RuntimeError, ~r/TURSO_AUTH_TOKEN is not set/, &prod_repo_config/0
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
end

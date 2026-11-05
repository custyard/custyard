defmodule Custyard.PortabilityRuntimeConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @variables ~w(STORAGE_PROVIDER PROXY_PROVIDER DATA_VOLUME_ID BUNNY_ORIGIN_SECRET FLY_APP_NAME DATABASE_PROVIDER DATABASE_URL TURSO_AUTH_TOKEN DATABASE_PATH BUNNY_DATABASE_URL BUNNY_DATABASE_AUTH_TOKEN MAIL_ADAPTER SECRET_KEY_BASE)

  setup do
    saved = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)
    System.put_env("MAIL_ADAPTER", "local")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))

    on_exit(fn ->
      for {name, value} <- saved do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end
    end)

    :ok
  end

  defp runtime do
    {config, _warnings} =
      with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: :prod) end)

    config[:custyard]
  end

  defp bunny_database do
    System.put_env("BUNNY_DATABASE_URL", "https://test.lite.bunnydb.net")
    System.put_env("BUNNY_DATABASE_AUTH_TOKEN", "isolated-test-token")
  end

  test "unconfigured local and automatic Fly deployments preserve their trust boundaries" do
    local = runtime()
    assert local[:storage_provider] == :local
    assert local[:proxy_provider] == :none
    refute local[:trust_proxy_headers]

    System.put_env("FLY_APP_NAME", "isolated-staging")
    fly = runtime()
    assert fly[:storage_provider] == :fly
    assert fly[:proxy_provider] == :fly
    assert fly[:trust_proxy_headers]
  end

  test "Bunny database aliases do not select the hosting or proxy provider" do
    bunny_database()
    local = runtime()
    assert local[Custyard.Repo][:turso_provider] == :bunny
    assert local[:storage_provider] == :local
    assert local[:proxy_provider] == :none

    System.put_env("FLY_APP_NAME", "isolated-staging")
    staging = runtime()
    assert staging[Custyard.Repo][:turso_provider] == :bunny
    assert staging[:storage_provider] == :fly
    assert staging[:proxy_provider] == :fly
  end

  test "Bunny hosting requires an explicit file-volume identity" do
    System.put_env("STORAGE_PROVIDER", "bunny")
    assert_raise RuntimeError, ~r/DATA_VOLUME_ID is required/, &runtime/0

    System.put_env("DATA_VOLUME_ID", "isolated-test-volume")
    assert runtime()[:data_volume_id] == "isolated-test-volume"
  end

  test "Bunny proxy cannot enable forwarded trust without a strong origin secret" do
    System.put_env("PROXY_PROVIDER", "bunny")

    for value <- [nil, "", "short-private-value"] do
      if is_nil(value),
        do: System.delete_env("BUNNY_ORIGIN_SECRET"),
        else: System.put_env("BUNNY_ORIGIN_SECRET", value)

      error = assert_raise RuntimeError, ~r/BUNNY_ORIGIN_SECRET/, &runtime/0
      refute Exception.message(error) =~ "short-private-value"
    end

    System.put_env("BUNNY_ORIGIN_SECRET", String.duplicate("s", 32))
    config = runtime()
    assert config[:proxy_provider] == :bunny
    assert config[:bunny_origin_secret] == String.duplicate("s", 32)
    refute config[:trust_proxy_headers]
  end

  test "unknown provider settings fail without echoing their values" do
    for variable <- ["STORAGE_PROVIDER", "PROXY_PROVIDER"] do
      System.put_env(variable, "private-invalid-provider")
      error = assert_raise RuntimeError, &runtime/0
      assert Exception.message(error) =~ variable
      refute Exception.message(error) =~ "private-invalid-provider"
      System.delete_env(variable)
    end
  end
end

defmodule Custyard.PortabilityRuntimeConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @variables ~w(STORAGE_PROVIDER PROXY_PROVIDER DATA_VOLUME_ID BUNNY_ORIGIN_SECRET FLY_APP_NAME DATABASE_PROVIDER DATABASE_URL TURSO_AUTH_TOKEN DATABASE_PATH BUNNY_DATABASE_URL BUNNY_DATABASE_AUTH_TOKEN MAIL_ADAPTER SECRET_KEY_BASE PHX_HOST CREDENTIAL_ENCRYPTION_KEY)

  setup do
    saved = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)
    # A complete configuration, so every problem below is the one under test.
    System.put_env("MAIL_ADAPTER", "local")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    System.put_env("PHX_HOST", "custyard.example.com")
    System.put_env("CREDENTIAL_ENCRYPTION_KEY", Base.encode64(String.duplicate("c", 32)))

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

  # config/runtime.exs never raises: a bad setting is a problem on the boot
  # verdict (Custyard.Boot.Env), which keeps the app from starting.
  defp problem(config, variable) do
    env = config[:boot_env]
    assert env.verdict == :unconfigured
    assert [%{variable: ^variable} = problem] = env.problems
    problem
  end

  defp bunny_database do
    System.put_env("BUNNY_DATABASE_URL", "https://test.lite.bunnydb.net")
    System.put_env("BUNNY_DATABASE_AUTH_TOKEN", "isolated-test-token")
  end

  test "unconfigured local and automatic Fly deployments preserve their trust boundaries" do
    local = runtime()
    assert local[:boot_env].verdict == :configured
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
    config = runtime()
    assert problem(config, "DATA_VOLUME_ID").kind == :missing
    assert config[:storage_provider] == :bunny
    assert config[:data_volume_id] == nil

    System.put_env("DATA_VOLUME_ID", "isolated-test-volume")
    config = runtime()
    assert config[:boot_env].verdict == :configured
    assert config[:data_volume_id] == "isolated-test-volume"
  end

  test "Bunny proxy cannot enable forwarded trust without a strong origin secret" do
    System.put_env("PROXY_PROVIDER", "bunny")

    for value <- [nil, "", "short-private-value"] do
      if is_nil(value),
        do: System.delete_env("BUNNY_ORIGIN_SECRET"),
        else: System.put_env("BUNNY_ORIGIN_SECRET", value)

      config = runtime()
      refute problem(config, "BUNNY_ORIGIN_SECRET").detail =~ "short-private-value"
      # No usable secret is configured, so CustyardWeb.Proxy refuses every
      # request but the health probes; forwarded headers stay untrusted.
      assert config[:proxy_provider] == :bunny
      assert config[:bunny_origin_secret] == nil
      refute config[:trust_proxy_headers]
    end

    System.put_env("BUNNY_ORIGIN_SECRET", String.duplicate("s", 32))
    config = runtime()
    assert config[:boot_env].verdict == :configured
    assert config[:proxy_provider] == :bunny
    assert config[:bunny_origin_secret] == String.duplicate("s", 32)
    refute config[:trust_proxy_headers]
  end

  test "unknown provider settings fail without echoing their values" do
    for variable <- ["STORAGE_PROVIDER", "PROXY_PROVIDER"] do
      System.put_env(variable, "private-invalid-provider")
      config = runtime()
      problem = problem(config, variable)
      assert problem.kind == :unsupported
      refute problem.detail =~ "private-invalid-provider"
      System.delete_env(variable)
    end
  end

  test "the configured storage provider is what Custyard.Storage checks" do
    saved = Application.fetch_env(:custyard, :storage_provider)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:custyard, :storage_provider, value)
        :error -> Application.delete_env(:custyard, :storage_provider)
      end
    end)

    System.put_env("STORAGE_PROVIDER", "bunny")
    System.put_env("DATA_VOLUME_ID", "isolated-test-volume")
    bunny_database()
    config = runtime()
    Application.put_env(:custyard, :storage_provider, config[:storage_provider])

    assert {:error, :volume_unverified, detail} =
             Custyard.Storage.check(
               repo_config: config[Custyard.Repo],
               data_volume_id: config[:data_volume_id],
               upload_dir: config[:upload_dir],
               attachment_dir: config[:attachment_dir],
               mountinfo: "35 28 0:28 / / rw - overlay overlay rw\n"
             )

    assert detail == "Bunny requires a mounted file volume at /data"

    Application.put_env(:custyard, :storage_provider, :local)
    assert :ok == Custyard.Storage.check(repo_config: config[Custyard.Repo])
  end

  test "an unknown storage provider stops release commands at the volume check" do
    System.put_env("STORAGE_PROVIDER", "private-invalid-provider")
    config = runtime()
    assert config[:storage_provider] == :invalid

    assert {:error, :provider_unsupported, detail} =
             Custyard.Storage.check(provider: config[:storage_provider])

    assert detail == "STORAGE_PROVIDER must be local, fly or bunny"
  end
end

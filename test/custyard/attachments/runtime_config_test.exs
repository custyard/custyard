defmodule Custyard.Attachments.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @keys ~w(CLAMAV_HOST CLAMAV_PORT CLAMAV_TIMEOUT_MS)

  setup do
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "scanner configuration is absent unless an endpoint is explicitly set" do
    refute Config.Reader.read!(@runtime, env: :test)[:custyard][:attachment_scanner]
    System.put_env("CLAMAV_HOST", "")
    refute Config.Reader.read!(@runtime, env: :test)[:custyard][:attachment_scanner]
  end

  test "private scanner endpoint receives bounded defaults" do
    System.put_env("CLAMAV_HOST", "scanner.internal")
    config = Config.Reader.read!(@runtime, env: :test)[:custyard]
    assert config[:attachment_scanner] == Custyard.Attachments.ClamAV

    assert config[:attachment_scanner_options] == [
             host: "scanner.internal",
             port: 3310,
             timeout: 10_000
           ]
  end

  test "unbounded timeout and invalid port fail configuration" do
    System.put_env("CLAMAV_HOST", "scanner.internal")
    System.put_env("CLAMAV_TIMEOUT_MS", "60001")
    assert_raise RuntimeError, fn -> Config.Reader.read!(@runtime, env: :test) end
    System.delete_env("CLAMAV_TIMEOUT_MS")
    System.put_env("CLAMAV_PORT", "0")
    assert_raise RuntimeError, fn -> Config.Reader.read!(@runtime, env: :test) end
  end
end

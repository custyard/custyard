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

  # runtime.exs never raises; an out-of-range value leaves attachments
  # quarantined and is a boot problem in production.
  test "unbounded timeout and invalid port leave the scanner unconfigured" do
    System.put_env("CLAMAV_HOST", "scanner.internal")

    for {name, value} <- [{"CLAMAV_TIMEOUT_MS", "60001"}, {"CLAMAV_PORT", "0"}] do
      System.put_env(name, value)

      refute Config.Reader.read!(@runtime, env: :test)[:custyard][:attachment_scanner]

      prod = Config.Reader.read!(@runtime, env: :prod)[:custyard]
      refute prod[:attachment_scanner]
      assert Enum.any?(prod[:boot_env].problems, &(&1.variable == name and &1.kind == :malformed))

      System.delete_env(name)
    end
  end

  test "a production scanner endpoint is configured from the boot verdict" do
    System.put_env("CLAMAV_HOST", "scanner.internal")
    System.put_env("CLAMAV_PORT", "3311")
    prod = Config.Reader.read!(@runtime, env: :prod)[:custyard]
    assert prod[:attachment_scanner] == Custyard.Attachments.ClamAV

    assert prod[:attachment_scanner_options] == [
             host: "scanner.internal",
             port: 3311,
             timeout: 10_000
           ]
  end
end

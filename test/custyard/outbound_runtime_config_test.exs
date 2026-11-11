defmodule Custyard.OutboundRuntimeConfigTest do
  use ExUnit.Case, async: false
  alias Config.Reader

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @key "OUTBOUND_DELIVERY_ENABLED"

  setup do
    previous = System.get_env(@key)

    on_exit(fn ->
      if previous, do: System.put_env(@key, previous), else: System.delete_env(@key)
    end)
  end

  test "the default enables delivery and an explicit false holds the restored queue" do
    System.delete_env(@key)
    assert Reader.read!(@runtime, env: :test)[:custyard][:outbound_delivery_enabled]
    System.put_env(@key, "false")
    refute Reader.read!(@runtime, env: :test)[:custyard][:outbound_delivery_enabled]
    System.put_env(@key, "true")
    assert Reader.read!(@runtime, env: :test)[:custyard][:outbound_delivery_enabled]
  end

  # runtime.exs never raises (Custyard.Boot.Env reports the problem and a
  # production boot serves the doctor card). A mistyped value must still never
  # enable sending.
  test "invalid recovery settings keep delivery stopped instead of enabling sending" do
    for value <- ["0", "1", "TRUE", "disabled"] do
      System.put_env(@key, value)

      refute Reader.read!(@runtime, env: :test)[:custyard][:outbound_delivery_enabled]

      prod = Reader.read!(@runtime, env: :prod)[:custyard]
      refute prod[:outbound_delivery_enabled]
      assert Enum.any?(prod[:boot_env].problems, &(&1.variable == @key and &1.kind == :malformed))
      assert prod[:boot_env].verdict == :unconfigured
    end
  end

  test "a blank value is unset, as for every other variable" do
    System.put_env(@key, "")
    assert Reader.read!(@runtime, env: :test)[:custyard][:outbound_delivery_enabled]
    assert Reader.read!(@runtime, env: :prod)[:custyard][:outbound_delivery_enabled]
  end
end

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

  test "invalid recovery settings fail boot rather than silently enabling sending" do
    for value <- ["", "0", "1", "TRUE", "disabled"] do
      System.put_env(@key, value)

      assert_raise RuntimeError, ~r/OUTBOUND_DELIVERY_ENABLED must be true or false/, fn ->
        Reader.read!(@runtime, env: :test)
      end
    end
  end
end

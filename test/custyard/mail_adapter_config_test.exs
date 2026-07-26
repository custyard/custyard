defmodule Custyard.MailAdapterConfigTest do
  # Mutates process-global env vars and reads config/runtime.exs — sequential only.
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    original = System.get_env("MAIL_ADAPTER")

    on_exit(fn ->
      if original do
        System.put_env("MAIL_ADAPTER", original)
      else
        System.delete_env("MAIL_ADAPTER")
      end
    end)

    :ok
  end

  defp read_prod_config! do
    Config.Reader.read!(@runtime_config, env: :prod)
  end

  describe "MAIL_ADAPTER in :prod" do
    # Operator login is magic-link-only, so silently keeping the in-memory
    # Local adapter locks everyone out with no error anywhere.
    test "an unset value refuses to boot" do
      System.delete_env("MAIL_ADAPTER")

      assert_raise RuntimeError, ~r/MAIL_ADAPTER is not set/, &read_prod_config!/0
    end

    test "an empty value is treated as unset" do
      System.put_env("MAIL_ADAPTER", "")

      assert_raise RuntimeError, ~r/MAIL_ADAPTER is not set/, &read_prod_config!/0
    end

    test "an unrecognized value refuses to boot and names it" do
      System.put_env("MAIL_ADAPTER", "lettermnit")

      assert_raise RuntimeError, ~r/"lettermnit", which is not recognized/, &read_prod_config!/0
    end

    test "the error lists the accepted values" do
      System.delete_env("MAIL_ADAPTER")

      error = assert_raise RuntimeError, &read_prod_config!/0

      for adapter <- ~w(mailgun sendgrid smtp postmark lettermint local) do
        assert error.message =~ adapter
      end
    end

    # A recognized adapter must get past the mail block. Reading the rest of
    # runtime.exs then fails on the next unset prod requirement, which is
    # the signal that the mail guard let it through.
    test "a recognized value passes the guard" do
      System.put_env("MAIL_ADAPTER", "lettermint")

      error = assert_raise RuntimeError, &read_prod_config!/0

      refute error.message =~ "MAIL_ADAPTER"
      assert error.message =~ "SECRET_KEY_BASE"
    end

    test "local passes the guard as an explicit opt-in" do
      System.put_env("MAIL_ADAPTER", "local")

      error = assert_raise RuntimeError, &read_prod_config!/0

      refute error.message =~ "MAIL_ADAPTER is not set"
      refute error.message =~ "not recognized"
    end
  end
end

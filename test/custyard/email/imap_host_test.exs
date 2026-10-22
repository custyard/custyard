defmodule Custyard.Email.ImapHostTest do
  # async: false - toggles :imap_allow_private_hosts.
  use ExUnit.Case, async: false

  alias Custyard.Email.ImapHost

  setup do
    Application.put_env(:custyard, :imap_allow_private_hosts, false)
    on_exit(fn -> Application.put_env(:custyard, :imap_allow_private_hosts, true) end)
    :ok
  end

  test "refuses IP literals" do
    assert {:error, :disallowed_host} = ImapHost.resolve("93.184.216.34")
    assert {:error, :disallowed_host} = ImapHost.resolve("::1")
  end

  test "refuses a name that resolves to loopback" do
    assert {:error, :disallowed_host} = ImapHost.resolve("localhost")
  end

  test "public?/1 rejects private, shared, link-local and reserved ranges" do
    for ip <- [
          {10, 1, 2, 3},
          {127, 0, 0, 1},
          {169, 254, 169, 254},
          {172, 16, 0, 1},
          {172, 31, 255, 255},
          {192, 168, 1, 1},
          {100, 64, 0, 1},
          {0, 0, 0, 0},
          {224, 0, 0, 1},
          {198, 18, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
        ] do
      refute ImapHost.public?(ip), "#{inspect(ip)} should not be public"
    end

    for ip <- [
          {93, 184, 216, 34},
          {172, 32, 0, 1},
          {100, 128, 0, 1},
          {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
        ] do
      assert ImapHost.public?(ip), "#{inspect(ip)} should be public"
    end
  end

  test "development may connect by name" do
    Application.put_env(:custyard, :imap_allow_private_hosts, true)
    assert {:ok, "localhost", nil} = ImapHost.resolve("localhost")
  end
end

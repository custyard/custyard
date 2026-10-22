defmodule Custyard.CredentialsTest do
  # async: false - swaps the credential keys in application env.
  use ExUnit.Case, async: false

  alias Custyard.Credentials

  setup do
    original = Application.get_env(:custyard, :credential_keys)
    on_exit(fn -> Application.put_env(:custyard, :credential_keys, original) end)
    :ok
  end

  defp put_keys(current, previous \\ []),
    do: Application.put_env(:custyard, :credential_keys, current: current, previous: previous)

  test "round-trips under the same context and never contains the plaintext" do
    assert {:ok, "v1:" <> _ = ciphertext} = Credentials.encrypt("hunter2", "ctx")
    refute ciphertext =~ "hunter2"
    assert {:ok, "hunter2"} = Credentials.decrypt(ciphertext, "ctx")
  end

  test "each encryption uses a fresh IV" do
    {:ok, a} = Credentials.encrypt("same", "ctx")
    {:ok, b} = Credentials.encrypt("same", "ctx")
    refute a == b
  end

  test "is bound to its context" do
    {:ok, ciphertext} = Credentials.encrypt("hunter2", "inbound_channel.imap_password")
    assert {:error, :invalid} = Credentials.decrypt(ciphertext, "other.context")
  end

  test "rejects tampering, garbage and unknown keys alike" do
    {:ok, "v1:" <> encoded} = Credentials.encrypt("hunter2", "ctx")
    raw = Base.url_decode64!(encoded, padding: false)
    <<head::binary-size(byte_size(raw) - 1), last>> = raw
    tampered = "v1:" <> Base.url_encode64(head <> <<Bitwise.bxor(last, 1)>>, padding: false)

    assert {:error, :invalid} = Credentials.decrypt(tampered, "ctx")
    assert {:error, :invalid} = Credentials.decrypt("v1:not-base64!", "ctx")
    assert {:error, :invalid} = Credentials.decrypt("plaintext", "ctx")
    assert {:error, :invalid} = Credentials.decrypt(nil, "ctx")

    {:ok, other_key_value} = Credentials.encrypt("hunter2", "ctx")
    put_keys(:crypto.strong_rand_bytes(32))
    assert {:error, :invalid} = Credentials.decrypt(other_key_value, "ctx")
  end

  test "a previous key still decrypts and marks the value stale" do
    old = :crypto.strong_rand_bytes(32)
    put_keys(old)
    {:ok, sealed} = Credentials.encrypt("hunter2", "ctx")
    refute Credentials.stale?(sealed)

    put_keys(:crypto.strong_rand_bytes(32), [old])
    assert {:ok, "hunter2"} = Credentials.decrypt(sealed, "ctx")
    assert Credentials.stale?(sealed)

    {:ok, resealed} = Credentials.encrypt("hunter2", "ctx")
    refute Credentials.stale?(resealed)
  end

  test "without a current key nothing is encrypted" do
    put_keys(nil)
    refute Credentials.configured?()
    assert {:error, :not_configured} = Credentials.encrypt("hunter2", "ctx")
  end
end

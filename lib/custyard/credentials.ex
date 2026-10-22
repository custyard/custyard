defmodule Custyard.Credentials do
  @moduledoc """
  Encryption at rest for third-party credentials Custyard must use later in
  plain form, such as a per-channel IMAP password
  (spec-inbound-channels, D8).

  AES-256-GCM with a random 96-bit IV. The ciphertext is
  `"v1:" <> Base64url(key_id <> iv <> tag <> ciphertext)`, where `key_id`
  is the first four bytes of the key's SHA-256, so a value names the key
  that sealed it. Every value is bound to a context string (additional
  authenticated data) such as `"inbound_channel.imap_password"`; a
  ciphertext copied into another column or record type does not decrypt.

  Keys come from `config :custyard, :credential_keys, current: key,
  previous: [key, ...]` (32 raw bytes each), set in `config/runtime.exs`
  from `CREDENTIAL_ENCRYPTION_KEY` and `CREDENTIAL_ENCRYPTION_KEY_PREVIOUS`
  (Base64 of 32 bytes; `openssl rand -base64 32`). The key is dedicated:
  deriving it from `SECRET_KEY_BASE` would make rotating session secrets
  destroy every stored credential. Rotation: set the new key as current and
  the old one as previous; `stale?/1` tells a caller to re-encrypt a value
  sealed with a previous key.

  Without a current key, `encrypt/2` returns `{:error, :not_configured}`;
  nothing falls back to plaintext.
  """

  @version "v1:"
  @aad_prefix "custyard:"
  @iv_bytes 12
  @tag_bytes 16

  @doc "True when a current key is configured."
  def configured?, do: not is_nil(current_key())

  @doc "Encrypt `plaintext` for `context`. `{:ok, ciphertext}` or `{:error, :not_configured}`."
  def encrypt(plaintext, context) when is_binary(plaintext) and is_binary(context) do
    case current_key() do
      nil ->
        {:error, :not_configured}

      key ->
        iv = :crypto.strong_rand_bytes(@iv_bytes)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad(context), true)

        {:ok,
         @version <> Base.url_encode64(key_id(key) <> iv <> tag <> ciphertext, padding: false)}
    end
  end

  @doc """
  Decrypt a value from `encrypt/2` for the same `context`. Returns
  `{:ok, plaintext}` or `{:error, :invalid}` for a malformed value, an
  unknown key, a different context or tampering. The reason never says
  which.
  """
  def decrypt(@version <> encoded, context) when is_binary(context) do
    with {:ok,
          <<id::binary-size(4), iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
            ciphertext::binary>>} <- Base.url_decode64(encoded, padding: false),
         key when is_binary(key) <- key_for(id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad(context),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :invalid}
    end
  end

  def decrypt(_value, _context), do: {:error, :invalid}

  @doc "True when `ciphertext` was sealed with a key other than the current one."
  def stale?(@version <> encoded) do
    case {Base.url_decode64(encoded, padding: false), current_key()} do
      {{:ok, <<id::binary-size(4), _rest::binary>>}, key} when is_binary(key) -> id != key_id(key)
      _ -> false
    end
  end

  def stale?(_value), do: false

  defp aad(context), do: @aad_prefix <> context

  defp key_id(key), do: binary_part(:crypto.hash(:sha256, key), 0, 4)

  defp key_for(id) do
    Enum.find([current_key() | previous_keys()], fn key ->
      is_binary(key) and key_id(key) == id
    end)
  end

  defp current_key, do: Keyword.get(config(), :current)
  defp previous_keys, do: Keyword.get(config(), :previous, [])

  defp config, do: Application.get_env(:custyard, :credential_keys, [])
end

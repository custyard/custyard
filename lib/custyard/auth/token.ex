defmodule Custyard.Auth.Token do
  @moduledoc """
  Shared primitive for high-entropy bearer tokens stored hashed at rest.

  Used for months-lived bearer credentials (prospect resume tokens, slug-claim
  confirmation tokens). Unlike the codebase's short-lived login token and
  permanent org credentials, these tokens are hashed before persistence so a
  database read never yields a live credential.

  SHA-256 of a 256-bit random value needs no KDF, and lookups stay indexed
  because hashing is deterministic. Plaintext tokens must NEVER be persisted —
  only hashes.
  """

  @doc """
  Generate a new 256-bit random token and its SHA-256 hash.

  Returns `{token, hash}`. The plaintext `token` is shown to the bearer exactly
  once; only `hash` may be stored.
  """
  @spec generate() :: {String.t(), String.t()}
  def generate do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {token, hash(token)}
  end

  @doc """
  Hash a presented token for storage or indexed lookup.
  """
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    Base.url_encode64(:crypto.hash(:sha256, token), padding: false)
  end
end

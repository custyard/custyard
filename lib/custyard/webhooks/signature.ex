defmodule Custyard.Webhooks.Signature do
  @moduledoc """
  Centralized webhook signature verification.

  Delegates to the appropriate adapter based on the source type.
  Supports HMAC-SHA256, HMAC-SHA1, and API key verification.
  """

  alias Custyard.Webhooks.Adapters

  @adapters %{
    lettermint: Adapters.Lettermint,
    zendesk: Adapters.Zendesk,
    intercom: Adapters.Intercom,
    slack: Adapters.Slack
  }

  @doc """
  Verify the webhook signature for the given source.

  ## Parameters
  - `source` - atom identifying the webhook source
  - `payload` - the raw request body (binary)
  - `signature` - the signature from the request header
  - `secret` - the shared secret for this source

  Returns `:ok` or `{:error, reason}`.
  """
  def verify(source, payload, signature, secret) do
    case Map.get(@adapters, source) do
      nil -> {:error, "unknown source: #{source}"}
      adapter -> adapter.verify_signature(payload, signature, secret)
    end
  end

  @doc """
  Verify a webhook using a simple API key comparison.

  Used for sources that authenticate via a static API key in a header
  rather than HMAC signatures.
  """
  def verify_api_key(provided_key, expected_key) when is_binary(provided_key) do
    if Plug.Crypto.secure_compare(provided_key, expected_key) do
      :ok
    else
      {:error, "invalid API key"}
    end
  end

  def verify_api_key(nil, _expected), do: {:error, "missing API key"}
end

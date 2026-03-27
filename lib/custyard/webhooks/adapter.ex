defmodule Custyard.Webhooks.Adapter do
  @moduledoc """
  Behaviour for webhook source adapters.

  Each adapter knows how to:
  1. Verify the signature/authenticity of an incoming webhook
  2. Normalize the payload into a unified message format
  """

  @type normalized_payload :: %{
          from: String.t(),
          to: String.t() | nil,
          subject: String.t(),
          body: String.t(),
          message_id: String.t() | nil,
          in_reply_to: String.t() | nil,
          references: String.t() | nil,
          headers: map(),
          source: atom(),
          metadata: map()
        }

  @doc """
  Verify the authenticity of an incoming webhook request.

  Returns `:ok` if the signature is valid, or `{:error, reason}` if not.
  The `conn` provides access to request headers for signature extraction.
  The `secret` is the shared secret configured for this webhook source.
  """
  @callback verify_signature(
              payload :: map(),
              signature :: String.t() | nil,
              secret :: String.t()
            ) :: :ok | {:error, String.t()}

  @doc """
  Normalize the source-specific payload into the unified message format.

  Returns:
  - `{:ok, normalized_payload()}` - Successfully normalized payload
  - `{:error, String.t()}` - Normalization failed
  - `{:bypass, term()}` - Payload requires special handling (e.g., Slack URL verification)
                         The caller should handle the bypass directly (return challenge, etc.)
  """
  @callback normalize(payload :: map()) ::
              {:ok, normalized_payload()} | {:error, String.t()} | {:bypass, term()}

  @doc """
  Returns the name of this adapter source (e.g., :lettermint, :zendesk).
  """
  @callback source_name() :: atom()

  @doc """
  Verify the request with full replay protection (optional callback).

  Adapters can implement this to verify both signature AND timestamp for
  replay protection. Falls back to `verify_signature/3` if not implemented.

  ## Parameters
  - `raw_body` - the raw request body (binary)
  - `timestamp` - timestamp string from request header (nil if not provided)
  - `signature` - the signature from the request header
  - `secret` - the shared secret for this source

  Returns `:ok`, `{:error, reason}`, or `:not_implemented` to fall back.
  """
  @callback verify_request(
              raw_body :: binary(),
              timestamp :: String.t() | nil,
              signature :: String.t() | nil,
              secret :: String.t()
            ) :: :ok | {:error, String.t()} | :not_implemented

  @optional_callbacks verify_request: 4
end

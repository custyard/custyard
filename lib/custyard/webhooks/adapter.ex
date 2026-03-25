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
  """
  @callback normalize(payload :: map()) :: {:ok, normalized_payload()} | {:error, String.t()}

  @doc """
  Returns the name of this adapter source (e.g., :lettermint, :zendesk).
  """
  @callback source_name() :: atom()
end

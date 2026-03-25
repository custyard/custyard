defmodule Custyard.Webhooks.Normalizer do
  @moduledoc """
  Normalizes webhook payloads from different sources into a unified format.

  Delegates to the appropriate adapter based on source type, then applies
  common post-processing (HTML stripping, subject defaults, etc.).
  """

  alias Custyard.Webhooks.Registry

  @doc """
  Normalize a webhook payload using the adapter for the given source.

  Returns `{:ok, normalized}` or `{:error, reason}`.
  """
  def normalize(source, params) do
    case Registry.get_adapter(source) do
      nil -> {:error, "unknown source: #{source}"}
      adapter -> adapter.normalize(params)
    end
  end

  @doc """
  Normalize a raw params map using the legacy Lettermint format.

  This provides backward compatibility with the existing `POST /api/webhook/inbound`
  endpoint that predates the routed webhook system.
  """
  def normalize_legacy(params) do
    alias Custyard.Webhooks.Adapters.Lettermint
    Lettermint.normalize(params)
  end
end

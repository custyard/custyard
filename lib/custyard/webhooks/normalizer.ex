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

end

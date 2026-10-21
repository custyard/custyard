defmodule Custyard.Attachments.Client do
  @moduledoc """
  HTTP fetch of one attachment body from the provider's signed URL.

  `fetch/2` returns the bytes, `{:error, :too_large}` once more than
  `max_bytes` have arrived (the download is abandoned, not truncated), or
  another error. Implementations: `Custyard.Attachments.FinchClient` in
  dev and production, `Custyard.Attachments.StubClient` in tests.
  """

  @callback fetch(url :: String.t(), max_bytes :: non_neg_integer()) ::
              {:ok, binary()} | {:error, :too_large | term()}

  @doc "The configured client module."
  def client,
    do: Application.get_env(:custyard, :attachment_client, Custyard.Attachments.FinchClient)
end

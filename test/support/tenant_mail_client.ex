defmodule Custyard.TestTenantMailClient do
  @moduledoc "Test transport for tenant-owned Lettermint sending credentials."
  @behaviour Swoosh.ApiClient

  @impl true
  def post(_url, _headers, _body, email) do
    config = Application.fetch_env!(:custyard, Custyard.Mailer)
    adapter = Keyword.fetch!(config, :adapter)

    if adapter == Swoosh.Adapters.Lettermint, do: raise("test transport cannot call itself")

    case adapter.deliver(email, config) do
      {:ok, response} ->
        {:ok, 202, [], Jason.encode!(%{message_id: response[:id], status: "queued"})}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

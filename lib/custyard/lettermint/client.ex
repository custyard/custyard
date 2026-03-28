defmodule Custyard.Lettermint.Client do
  @moduledoc """
  Behaviour for Lettermint API interactions.

  Custyard owns the Lettermint integration — routes are created and deleted
  programmatically when organizations and projects are managed. Operators
  never see callback URLs or manage routes directly.

  Implementations:
  - `Custyard.Lettermint.HttpClient` — production HTTP client
  - `Custyard.Lettermint.MockClient` — dev/test stub
  """

  @doc """
  Create a route in Lettermint.

  Returns `{:ok, %{"id" => lettermint_route_id}}` on success.
  """
  @callback create_route(params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Delete a route in Lettermint by its remote ID.
  """
  @callback delete_route(lettermint_route_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Returns the configured Lettermint client module.

  Raises if `:custyard, :lettermint` config is missing or has no `:client` key.
  """
  def client do
    :custyard
    |> Application.get_env(:lettermint, [])
    |> Keyword.fetch!(:client)
  end
end

defmodule Custyard.Lettermint.Client do
  @moduledoc """
  Behaviour for Lettermint API interactions.

  Custyard owns the Lettermint integration — routes are created and deleted
  programmatically when organizations and projects are managed. Operators
  never see callback URLs or manage routes directly.

  Implementations:
  - `Custyard.Lettermint.HttpClient` — production HTTP client
  - `Custyard.Lettermint.MockClient` — dev/test stub

  ## Route shape

  `create_route/1` and `get_route/1` both return `{:ok, route}` where `route`
  is the UNWRAPPED Lettermint route map with string keys:

    * `"id"` — remote route ID
    * `"slug"`, `"name"`, `"route_type"`
    * `"inbound_route_domain"` — catch-all domain (`<id>.lettermint.app`);
      any local part and plus tag reaches the route. `nil` for non-inbound routes.
    * `"inbound_address"` — permanent compatibility address
      (`<uuid>@inbound.lettermint.co`, no plus addressing)
    * `"inbound_domain"` — operator-configured custom domain, nullable
    * `"inbound_domain_verified_at"` — ISO8601 datetime string, nullable

  The HTTP API wraps the route in `{"data": ...}` on create (201) but returns
  it bare on fetch; implementations must normalize so callers never see the
  wrapper. Older API responses may omit the domain keys.

  ## Domain shape

  `list_domains/0` returns `{:ok, domains}`: every sending domain on the
  team, each a map with string keys `"id"`, `"domain"` and `"status"`.
  Lettermint statuses are `verified`, `partially_verified`,
  `pending_verification` and `failed_verification`. The channel
  sending-domain check (docs/design/spec-inbound-channels.md, D3) compares a
  channel's public address domain against this list. Implementations follow
  pagination so callers always see the full list.
  """

  @doc """
  Create a route in Lettermint.

  Returns `{:ok, route}` with the unwrapped route map (see module doc).
  """
  @callback create_route(params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Fetch a route from Lettermint by its remote ID.

  Returns `{:ok, route}` with the unwrapped route map (see module doc).
  """
  @callback get_route(lettermint_route_id :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Delete a route in Lettermint by its remote ID.
  """
  @callback delete_route(lettermint_route_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  List the team's sending domains (see module doc, Domain shape).
  """
  @callback list_domains() :: {:ok, [map()]} | {:error, term()}

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

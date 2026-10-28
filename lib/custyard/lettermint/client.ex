defmodule Custyard.Lettermint.Client do
  @environment Application.compile_env(:custyard, :env, :prod)
  @moduledoc """
  Behaviour for Lettermint API interactions.

  Tenant administrators import provider routes and bind manually created
  webhooks through Email setup. Older organization provisioning APIs remain
  available and use the owning tenant's Team credentials.

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
  channel's selected sending domain against this list. Implementations follow
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
  Set (or clear, with nil) the route's custom inbound domain, an exact
  domain such as `help.example.com` or a left-hand wildcard such as
  `*.m.example.com` (`PUT /routes/{id}` with
  `inbound_settings.inbound_domain`). Lettermint resets verification when
  the domain changes.

  Returns `{:ok, route}` with the unwrapped route map (see module doc).
  """
  @callback set_inbound_domain(lettermint_route_id :: String.t(), domain :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Ask Lettermint to check the route's custom domain MX record
  (`POST /routes/{id}/verify-inbound-domain`).

  Returns `{:ok, result}` where `result` has string keys `"verified"`
  (boolean), `"message"`, `"expected_mx_records"` and `"found_mx_records"`
  (lists of strings, possibly absent).
  """
  @callback verify_inbound_domain(lettermint_route_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  List the team's sending domains (see module doc, Domain shape).
  """
  @callback list_domains() :: {:ok, [map()]} | {:error, term()}

  @doc "Find an exact sending domain available to the selected project, including unrestricted domains."
  @callback get_sending_domain(String.t()) :: {:ok, map() | nil} | {:error, term()}

  @doc false
  def find_domain(domains, domain) when is_list(domains) and is_binary(domain) do
    wanted = String.downcase(domain)

    Enum.find(domains, fn
      %{"domain" => candidate} when is_binary(candidate) -> String.downcase(candidate) == wanted
      _ -> false
    end)
  end

  @doc "Retrieve a retained webhook delivery; its payload is secret and must remain in memory."
  @callback get_webhook_delivery(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks get_webhook_delivery: 2

  @doc """
  Returns the configured Lettermint client module.

  Raises if `:custyard, :lettermint` config is missing or has no `:client` key.
  """
  def client do
    :custyard
    |> Application.get_env(:lettermint, [])
    |> Keyword.fetch!(:client)
  end

  @doc "Call a management operation with the owning tenant's credentials."
  def call(operation, args, tenant_id \\ nil) do
    module = client()

    cond do
      is_nil(tenant_id) ->
        apply(module, operation, args)

      Application.get_env(:custyard, :env, @environment) in [:dev, :test] and
          module not in [Custyard.Lettermint.HttpClient, Custyard.Lettermint.DisabledClient] ->
        apply(module, operation, args)

      true ->
        with {:ok, config} <- Custyard.EmailSetup.management_config(tenant_id) do
          if operation in [:list_domains, :get_sending_domain] and is_nil(config[:project_id]),
            do: {:error, :project_required},
            else: apply(Custyard.Lettermint.HttpClient, operation, args ++ [config])
        end
    end
  end
end

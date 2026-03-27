defmodule CustyardWeb.OriginValidator do
  @moduledoc """
  Validates WebSocket connection origins for LiveView.

  Allows connections from:
  1. The configured PHX_HOST
  2. Any organization's custom_domain from the database

  This enables custom domain portals to use LiveView WebSockets.

  ## Usage in Endpoint socket config (MFA with arity 2)

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [check_origin: {CustyardWeb.OriginValidator, :check_origin?, []}],
        longpoll: [check_origin: {CustyardWeb.OriginValidator, :check_origin?, []}]
  """

  alias Custyard.{Organization, Repo}
  import Ecto.Query

  @doc """
  Check origin for socket connections (arity 2 for Phoenix MFA callback).

  Phoenix passes a URI struct and opts. Returns true if the origin matches:
  - The configured PHX_HOST (or localhost in dev/test)
  - Any organization's custom_domain from the database
  """
  @spec check_origin?(URI.t(), keyword()) :: boolean()
  def check_origin?(%URI{host: host}, _opts) when is_binary(host) do
    require Logger
    host_lower = String.downcase(host)
    result = valid_host?(host_lower)

    unless result do
      Logger.warning(
        "[OriginValidator] Rejected host=#{inspect(host_lower)} " <>
          "primary_host=#{inspect(primary_host())} env=#{inspect(Application.get_env(:custyard, :env))}"
      )
    end

    result
  end

  def check_origin?(_uri, _opts), do: false

  @doc """
  Check origin from string (for testing and backwards compatibility).
  """
  @spec check_origin(String.t()) :: boolean()
  def check_origin(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) and host != "" ->
        check_origin?(%URI{host: host}, [])

      _ ->
        false
    end
  end

  def check_origin(_), do: false

  @doc """
  Returns a list of valid origin patterns for check_origin configuration.

  Includes PHX_HOST and all configured custom domains.
  Useful for debugging or static configuration.
  """
  @spec list_valid_origins() :: [String.t()]
  def list_valid_origins do
    custom_domains = list_custom_domains()
    primary_host = primary_host()

    origins =
      if primary_host do
        ["//" <> primary_host | Enum.map(custom_domains, &("//" <> &1))]
      else
        Enum.map(custom_domains, &("//" <> &1))
      end

    # Add localhost for dev
    if Application.get_env(:custyard, :env) in [:dev, :test] do
      ["//localhost" | origins]
    else
      origins
    end
  end

  # Check if the host is valid (either PHX_HOST or a custom domain)
  defp valid_host?(host) do
    host_lower = String.downcase(host)

    cond do
      # Always allow localhost in dev/test
      host_lower == "localhost" and Application.get_env(:custyard, :env) in [:dev, :test] ->
        true

      # Check against primary host
      host_lower == primary_host_lower() ->
        true

      # Check against custom domains in database
      custom_domain_exists?(host_lower) ->
        true

      true ->
        false
    end
  end

  defp primary_host do
    case Application.get_env(:custyard, CustyardWeb.Endpoint) do
      nil -> nil
      config -> get_in(config, [:url, :host])
    end
  end

  defp primary_host_lower do
    case primary_host() do
      nil -> ""
      host -> String.downcase(host)
    end
  end

  # Query the database for custom domains
  defp list_custom_domains do
    query =
      from o in Organization,
        where: not is_nil(o.custom_domain) and o.custom_domain != "",
        select: o.custom_domain

    Repo.all(query)
  rescue
    # Handle case where repo is not started (e.g., during compilation)
    _ -> []
  end

  defp custom_domain_exists?(host) do
    query =
      from o in Organization,
        where: fragment("lower(?)", o.custom_domain) == ^host,
        select: true,
        limit: 1

    Repo.one(query) == true
  rescue
    # Handle case where repo is not started
    _ -> false
  end
end

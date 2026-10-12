defmodule Custyard.Acknowledgments.Config do
  @moduledoc """
  Configuration for one source-isolated acknowledgment subscription.

  Messages raised or logged here name environment variables, never their
  values: the URL carries the broker password.
  """
  require Logger
  require Record
  alias Custyard.Acknowledgments.Evidence

  Record.defrecordp(
    :amqp_params_network,
    Record.extract(:amqp_params_network, from_lib: "amqp_client/include/amqp_client.hrl")
  )

  @url_variable "ACKNOWLEDGMENTS_AMQP_URL"
  @source_variable "ACKNOWLEDGMENTS_SOURCE"

  # Plaintext amqp, or amqps without certificate verification, is acceptable
  # only where traffic stays on the machine or on Fly's private network.
  @local_hosts ~w(localhost 127.0.0.1 ::1)
  @private_host_suffixes ~w(.internal .flycast)

  def load do
    Keyword.merge(
      [
        queue: "custyard.acknowledgments",
        prefetch: 1,
        retry_delays: [10_000, 60_000, 300_000],
        confirm_timeout: 5_000,
        reconnect_delay: 5_000
      ],
      Application.get_env(:custyard, :acknowledgments, [])
    )
  end

  @doc "The two secrets a subscription needs, by name."
  def required_variables, do: [@url_variable, @source_variable]

  @doc """
  Whether the subscription should run: `:disabled`, `:not_configured` (neither
  URL nor source), `{:incomplete, missing_variable}` or `:configured`.
  """
  def mode(config) do
    if config[:enabled], do: connection_mode(config), else: :disabled
  end

  @doc "Whether URL and source are present, whatever `:enabled` says."
  def connection_mode(config) do
    case {present?(config[:url]), present?(config[:source])} do
      {false, false} -> :not_configured
      {true, false} -> {:incomplete, @source_variable}
      {false, true} -> {:incomplete, @url_variable}
      {true, true} -> :configured
    end
  end

  @doc """
  Decides at application start whether the consumer runs. Returns `:disabled`,
  `:not_configured` (logged once) or `:enabled` after validation. Incomplete or
  invalid configuration raises, so the application refuses to start.
  """
  def startup(config \\ load(), env \\ Application.get_env(:custyard, :env)) do
    case mode(config) do
      :disabled ->
        :disabled

      :not_configured ->
        Logger.warning(
          "Colonel acknowledgments are enabled but not configured; set #{@url_variable} " <>
            "and #{@source_variable}, or ACKNOWLEDGMENTS_ENABLED=false"
        )

        :not_configured

      {:incomplete, missing} ->
        raise ArgumentError,
              "Colonel acknowledgments are enabled but #{missing} is not set; set both " <>
                "#{@url_variable} and #{@source_variable}, or ACKNOWLEDGMENTS_ENABLED=false"

      :configured ->
        validate!(config)

        if env == :prod and plaintext_remote?(config[:url]),
          do:
            Logger.warning(
              "#{@url_variable} uses plaintext amqp to a host outside localhost, " <>
                "*.internal and *.flycast; use amqps with verify=verify_peer"
            )

        :enabled
    end
  end

  @doc "nil for a valid configuration, otherwise validate!/1's message (which names no values)."
  def validation_error(config) do
    validate!(config)
    nil
  rescue
    error in ArgumentError -> error.message
  end

  def validate!(config) do
    Enum.each([:url, :source, :queue], &required_string!(config, &1))
    bounded_integer!(config, :prefetch, 1..100)
    Enum.each([:confirm_timeout, :reconnect_delay], &bounded_integer!(config, &1, 1..300_000))
    validate_delays!(config[:retry_delays])
    validate_identity!(config)
    config
  end

  @doc """
  Parses a broker URI without any network access. `:amqp_uri` errors embed the
  whole URI, password included, so every failure collapses to `:error`; a URI
  without a host (an in-VM direct connection) is refused too.
  """
  def network_params(url) when is_binary(url) do
    # :amqp_uri resolves auth mechanism and TLS verify names with
    # list_to_existing_atom/1; until these modules load (lazily, outside an
    # embedded release) a valid `amqplain` or `verify_none` would not parse.
    Enum.each([:amqp_auth_mechanisms, :ssl], &Code.ensure_loaded/1)

    case :amqp_uri.parse(String.to_charlist(url)) do
      {:ok, params} when Record.is_record(params, :amqp_params_network) -> {:ok, params}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  def network_params(_), do: :error

  defp plaintext_remote?(url) do
    case network_params(url) do
      {:ok, params} ->
        amqp_params_network(params, :ssl_options) == :none and not trusted_host?(params)

      :error ->
        false
    end
  end

  # An amqps URI without `verify` leaves OTP's client default, verify_peer;
  # any other value (verify_none) lets anyone on the path read the broker
  # password and impersonate the broker.
  defp unverified_tls_remote?(url) do
    with {:ok, params} <- network_params(url),
         options when is_list(options) <- amqp_params_network(params, :ssl_options) do
      Keyword.get(options, :verify, :verify_peer) != :verify_peer and not trusted_host?(params)
    else
      _ -> false
    end
  end

  defp trusted_host?(params) do
    host = params |> amqp_params_network(:host) |> to_string() |> String.downcase()
    host in @local_hosts or String.ends_with?(host, @private_host_suffixes)
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp required_string!(config, key) do
    unless is_binary(config[key]) and byte_size(config[key]) > 0,
      do: raise(ArgumentError, "acknowledgments #{key} must be configured")
  end

  defp bounded_integer!(config, key, range) do
    unless is_integer(config[key]) and config[key] in range,
      do: raise(ArgumentError, "acknowledgments #{key} is outside its permitted range")
  end

  defp validate_delays!(delays) do
    unless is_list(delays) and Enum.all?(delays, &(is_integer(&1) and &1 in 1..86_400_000)),
      do:
        raise(
          ArgumentError,
          "acknowledgments retry_delays must be positive milliseconds up to one day"
        )
  end

  defp validate_identity!(config) do
    unless byte_size(config[:queue]) <= 200,
      do: raise(ArgumentError, "acknowledgments queue must be at most 200 bytes")

    unless URI.parse(config[:url]).scheme in ["amqp", "amqps"],
      do: raise(ArgumentError, "acknowledgments URL must use amqp or amqps")

    unless match?({:ok, _}, network_params(config[:url])),
      do: raise(ArgumentError, "acknowledgments URL is not a valid AMQP URI with a host")

    if unverified_tls_remote?(config[:url]),
      do:
        raise(
          ArgumentError,
          "acknowledgments URL turns off TLS certificate verification for a host outside " <>
            "localhost, *.internal and *.flycast; use verify=verify_peer with a cacertfile"
        )

    unless Evidence.valid_identity?(config[:source]),
      do: raise(ArgumentError, "acknowledgments source is invalid")
  end
end

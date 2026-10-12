defmodule Custyard.Acknowledgments.Config do
  @moduledoc "Configuration for one source-isolated acknowledgment subscription."
  alias Custyard.Acknowledgments.Evidence

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

  def validate!(config) do
    Enum.each([:url, :source, :queue], &required_string!(config, &1))
    bounded_integer!(config, :prefetch, 1..100)
    Enum.each([:confirm_timeout, :reconnect_delay], &bounded_integer!(config, &1, 1..300_000))
    validate_delays!(config[:retry_delays])
    validate_identity!(config)
    config
  end

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

    unless Evidence.valid_identity?(config[:source]),
      do: raise(ArgumentError, "acknowledgments source is invalid")
  end
end

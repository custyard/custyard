defmodule Custyard.Webhooks.Registry do
  @moduledoc """
  Registry of available webhook source adapters.

  Maps source names to their adapter modules for dynamic dispatch.
  """

  alias Custyard.Webhooks.Adapters

  @adapters %{
    lettermint: Adapters.Lettermint,
    zendesk: Adapters.Zendesk,
    intercom: Adapters.Intercom,
    slack: Adapters.Slack
  }

  @doc "Returns the adapter module for the given source name, or nil."
  def get_adapter(source) when is_atom(source), do: Map.get(@adapters, source)

  def get_adapter(source) when is_binary(source) do
    case safe_to_atom(source) do
      nil -> nil
      atom -> Map.get(@adapters, atom)
    end
  end

  @doc "Returns all registered adapter source names."
  def sources, do: Map.keys(@adapters)

  @doc "Returns true if the source is a known adapter."
  def known_source?(source) when is_atom(source), do: Map.has_key?(@adapters, source)

  def known_source?(source) when is_binary(source) do
    case safe_to_atom(source) do
      nil -> false
      atom -> Map.has_key?(@adapters, atom)
    end
  end

  defp safe_to_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end

defmodule Custyard.Lettermint.MockClient do
  @moduledoc """
  Mock Lettermint API client for development and testing.

  Returns predictable responses without making HTTP requests.
  """

  @behaviour Custyard.Lettermint.Client

  @impl true
  def create_route(_params) do
    {:ok, %{"id" => "lm_route_#{:erlang.unique_integer([:positive])}"}}
  end

  @impl true
  def delete_route(_lettermint_route_id) do
    :ok
  end
end

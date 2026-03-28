defmodule Custyard.Lettermint.FailingMockClient do
  @moduledoc """
  Mock Lettermint client that simulates API failures for testing error handling.

  Configure behavior via process dictionary:
  - `{:failing_mock_client, :create_route}` - error tuple to return from create_route/1
  - `{:failing_mock_client, :delete_route}` - error tuple to return from delete_route/1

  Example:
      Process.put({:failing_mock_client, :delete_route}, {:error, {:api_error, 500, "Internal Server Error"}})
  """

  @behaviour Custyard.Lettermint.Client

  @impl true
  def create_route(_params) do
    case Process.get({:failing_mock_client, :create_route}) do
      nil -> {:error, {:api_error, 503, "Service Unavailable"}}
      error -> error
    end
  end

  @impl true
  def delete_route(_lettermint_route_id) do
    case Process.get({:failing_mock_client, :delete_route}) do
      nil -> {:error, {:api_error, 503, "Service Unavailable"}}
      error -> error
    end
  end
end

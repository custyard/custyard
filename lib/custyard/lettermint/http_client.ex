defmodule Custyard.Lettermint.HttpClient do
  @moduledoc """
  Production HTTP client for the Lettermint API.

  Uses Finch to make HTTP requests. Requires `LETTERMINT_API_URL` and
  `LETTERMINT_API_KEY` to be configured at runtime.
  """

  @behaviour Custyard.Lettermint.Client

  @impl true
  def create_route(params) do
    url = api_url("/routes")
    body = Jason.encode!(params)

    case request(:post, url, body) do
      {:ok, %Finch.Response{status: status, body: response_body}}
      when status in [200, 201] ->
        case Jason.decode(response_body) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, decode_error} ->
            {:error, {:decode_failed, decode_error, response_body}}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def delete_route(lettermint_route_id) do
    url = api_url("/routes/#{lettermint_route_id}")

    case request(:delete, url, nil) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Finch.Response{status: 404}} ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp request(method, url, body) do
    headers = [
      {"authorization", "Bearer #{api_key()}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    Finch.build(method, url, headers, body)
    |> Finch.request(Custyard.Finch)
  end

  defp config do
    Application.get_env(:custyard, :lettermint)
  end

  defp api_url(path) do
    base = config()[:api_url] || raise "LETTERMINT_API_URL not configured"
    String.trim_trailing(base, "/") <> path
  end

  defp api_key do
    config()[:api_key] || raise "LETTERMINT_API_KEY not configured"
  end
end

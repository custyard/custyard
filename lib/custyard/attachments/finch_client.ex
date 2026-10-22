defmodule Custyard.Attachments.FinchClient do
  @moduledoc """
  Streams an attachment from its signed URL through the application's Finch
  pool, giving up as soon as the body exceeds the allowed size.

  Only `https` URLs with a hostname are fetched: the webhook is signature
  verified, but a URL is still data from outside and must not be able to
  point the fetcher at an internal address.
  """

  @behaviour Custyard.Attachments.Client

  @receive_timeout 30_000

  @impl true
  def fetch(url, max_bytes) when is_binary(url) and is_integer(max_bytes) do
    with :ok <- check_url(url) do
      stream(url, max_bytes)
    end
  end

  defp check_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        if ip_literal?(host), do: {:error, :disallowed_url}, else: :ok

      _uri ->
        {:error, :disallowed_url}
    end
  end

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[]"))) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp stream(url, max_bytes) do
    request = Finch.build(:get, url)

    result =
      Finch.stream(request, Custyard.Finch, {nil, 0, []}, &collect(&1, &2, max_bytes),
        receive_timeout: @receive_timeout
      )

    case result do
      {:ok, {200, _size, chunks}} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:ok, {status, _size, _chunks}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :throw, :too_large -> {:error, :too_large}
  end

  defp collect({:status, status}, {_status, size, chunks}, _max), do: {status, size, chunks}
  defp collect({:headers, _headers}, acc, _max), do: acc

  defp collect({:data, data}, {status, size, chunks}, max_bytes) do
    size = size + byte_size(data)
    if size > max_bytes, do: throw(:too_large), else: {status, size, [data | chunks]}
  end
end

defmodule CustyardWeb.ClientIP do
  @moduledoc """
  Client IP extraction with a single trust boundary for proxy headers.

  Extracted from `CustyardWeb.Plugs.LoginRateLimit` so every rate-limit
  surface (plugs and LiveViews) shares one discipline:

  Proxy headers are only honored when `config :custyard,
  :trust_proxy_headers` is `true` (default `false`; enabled for the Fly
  deployment in `config/runtime.exs`). Otherwise the transport peer
  address is used directly, so clients cannot spoof `X-Forwarded-For`
  to dodge rate limits or frame another address.

  When trusted, header preference for HTTP requests is:

  1. `Fly-Client-IP` — set by Fly.io, a single trusted value
  2. `X-Forwarded-For` — rightmost entry. The trusted edge proxy
     *appends* the peer it saw; it does not strip client-supplied
     entries. Only the rightmost value is proxy-authoritative — keying
     on the leftmost would let any client mint arbitrary rate-limit
     keys or frame a victim address by sending its own header.
  3. `conn.remote_ip` — direct connection fallback

  A header value that does not parse as an IP address (malformed or
  spoofed garbage) is ignored and the next source is tried, ending at
  the peer address — extraction never raises on malformed input.

  For LiveView, `from_peer_data/2` applies the same rules to the
  `:peer_data` and `:x_headers` socket `connect_info` (which the
  endpoint provides). Note `Fly-Client-IP` is not an `x-` header, so it
  is not visible over `:x_headers`; the rightmost `X-Forwarded-For`
  entry is proxy-appended, so the trusted LiveView path still resolves
  the real client even though a websocket client controls every entry
  to its left.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @doc """
  Returns the client IP for an HTTP request as a string.

  Always returns a usable key: falls back to `conn.remote_ip`, or the
  literal `"unknown"` if even that is unreadable.
  """
  @spec from_conn(Plug.Conn.t()) :: String.t()
  def from_conn(conn) do
    if trust_proxy_headers?() do
      from_trusted_headers(conn) || address_to_string(conn.remote_ip)
    else
      address_to_string(conn.remote_ip)
    end
  end

  @doc """
  Returns the client IP for a LiveView socket from its `connect_info`.

  `peer_data` is the `:peer_data` map (or `nil`), `x_headers` the
  `:x_headers` list. Returns `nil` when neither source yields an
  address (e.g. connect info was not captured).
  """
  @spec from_peer_data(map() | nil, [{String.t(), String.t()}] | nil) :: String.t() | nil
  def from_peer_data(peer_data, x_headers) do
    if trust_proxy_headers?() do
      forwarded_ip(x_headers || []) || peer_data_ip(peer_data)
    else
      peer_data_ip(peer_data)
    end
  end

  @doc """
  Convenience for LiveView `mount/3`: reads `:peer_data` and
  `:x_headers` from the socket's connect info and applies
  `from_peer_data/2`. Only callable while connect info is available
  (i.e. during mount).
  """
  @spec from_socket(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def from_socket(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers)
    from_peer_data(peer_data, x_headers)
  end

  ## Internal

  defp from_trusted_headers(conn) do
    single_ip(get_req_header(conn, "fly-client-ip")) ||
      rightmost_forwarded_ip(get_req_header(conn, "x-forwarded-for"))
  end

  defp forwarded_ip(x_headers) do
    values = for {"x-forwarded-for", value} <- x_headers, do: value
    rightmost_forwarded_ip(values)
  end

  defp single_ip([value | _rest]), do: validate_ip(String.trim(value))
  defp single_ip(_none), do: nil

  # X-Forwarded-For arrives as "client-supplied..., proxy-appended": the
  # trusted edge appends the peer it saw, so only the RIGHTMOST entry
  # (across all header instances) is authoritative. Everything to its
  # left is attacker-controlled input.
  defp rightmost_forwarded_ip([]), do: nil

  defp rightmost_forwarded_ip(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> List.last()
    |> String.trim()
    |> validate_ip()
  end

  defp validate_ip(value) do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, _address} -> value
      {:error, _reason} -> nil
    end
  end

  defp peer_data_ip(%{address: address}), do: address_to_string(address)
  defp peer_data_ip(_other), do: nil

  defp address_to_string(address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> "unknown"
      chars -> to_string(chars)
    end
  end

  defp trust_proxy_headers? do
    Application.get_env(:custyard, :trust_proxy_headers, false)
  end
end

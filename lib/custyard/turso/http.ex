defmodule Custyard.Turso.HTTP do
  @moduledoc """
  One persistent HTTP/1.1 connection, used synchronously.

  Each `Custyard.Turso.Connection` owns one. DBConnection runs its callbacks
  in whichever process checked the connection out, so the socket stays in
  passive mode and the caller reads its own response.
  """

  defstruct [:conn, :endpoint, :transport_opts, :used_at, :max_idle]

  @type t :: %__MODULE__{}

  @default_connect_timeout 5_000

  # A server closes a keep-alive connection left idle, and only a read
  # notices: over TLS a read must wait for it, as one with a zero timeout
  # returns before the close is processed. The wait costs every request it
  # precedes, so it is spent on a connection idle long enough to be closed.
  @close_wait 1
  @idle_check_after 50

  # Turso closes a keep-alive connection idle for about 7 s (measured from Fly
  # ams to aws-eu-west-1). From a shared-CPU machine the 1 ms read above does
  # not notice that close, and the next request fails with "socket closed";
  # it is not sent again. A connection idle for longer than this is replaced
  # before a request instead of trusting the read. Pings only close it, so an
  # idle pool does not reconnect every few seconds.
  @default_max_idle 5_000

  @spec connect(Custyard.Turso.Protocol.endpoint(), keyword) ::
          {:ok, t} | {:error, Exception.t()}
  def connect(endpoint, opts \\ []) do
    transport_opts =
      Keyword.merge(
        [timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout)],
        Keyword.get(opts, :transport_opts, [])
      )

    http = %__MODULE__{
      endpoint: endpoint,
      transport_opts: transport_opts,
      max_idle: Keyword.get(opts, :max_idle, @default_max_idle)
    }

    with {:ok, conn} <- open(endpoint, transport_opts), do: {:ok, used(%{http | conn: conn})}
  end

  @doc """
  POSTs `body` to `path` on `endpoint` and reads the whole response.

  Reconnects first when the server closed the previous connection, it sat
  idle longer than `:max_idle`, or the request is for another endpoint. A request that then fails is never sent
  again, not even one that failed while being written: the server may have
  received all of it and run it.
  """
  @spec post(t, Custyard.Turso.Protocol.endpoint(), String.t(), list, iodata, timeout) ::
          {:ok, t, non_neg_integer, binary} | {:error, t, Exception.t()}
  def post(http, endpoint, path, headers, body, timeout) do
    deadline = deadline(timeout)

    http =
      cond do
        stale?(http) -> retire(http)
        idle_for(http) >= @idle_check_after -> notice_close(http)
        true -> http
      end

    with {:ok, http} <- ensure_open(http, endpoint),
         {:ok, conn, ref} <- request(http, path, headers, body) do
      receive_response(%{http | conn: conn}, ref, deadline)
    end
  end

  @doc """
  Notices a connection the server closed while it sat idle, without a round
  trip, and replaces it. A connection idle longer than `:max_idle` is closed
  and left for the next request to reopen.
  """
  @spec check(t) :: {:ok, t} | {:error, t, Exception.t()}
  def check(http) do
    if stale?(http),
      do: {:ok, retire(http)},
      else: ensure_open(notice_close(http), http.endpoint)
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: nil}), do: :ok

  def close(%__MODULE__{conn: conn}) do
    {:ok, _conn} = Mint.HTTP1.close(conn)
    :ok
  end

  defp stale?(%__MODULE__{conn: nil}), do: false
  defp stale?(http), do: idle_for(http) >= http.max_idle

  defp retire(http) do
    {:ok, conn} = Mint.HTTP1.close(http.conn)
    %{http | conn: conn}
  end

  # Nothing to read means the connection is still open; a close the server
  # sent marks it closed.
  defp notice_close(%__MODULE__{conn: nil} = http), do: http

  defp notice_close(%__MODULE__{conn: conn} = http) do
    case Mint.HTTP1.recv(conn, 0, @close_wait) do
      {:ok, conn, _responses} -> %{http | conn: conn}
      {:error, conn, _error, _responses} -> %{http | conn: conn}
    end
  end

  defp request(http, path, headers, body) do
    case Mint.HTTP1.request(http.conn, "POST", path, headers, body) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, error} ->
        # Part of the request may be on the wire, so the connection cannot
        # take another.
        {:ok, conn} = Mint.HTTP1.close(conn)
        {:error, %{http | conn: conn}, error}
    end
  end

  defp ensure_open(%__MODULE__{conn: conn, endpoint: endpoint} = http, endpoint)
       when conn != nil do
    if Mint.HTTP1.open?(conn), do: {:ok, http}, else: reopen(http, endpoint)
  end

  defp ensure_open(http, endpoint), do: reopen(http, endpoint)

  defp reopen(http, endpoint) do
    close(http)

    case open(endpoint, http.transport_opts) do
      {:ok, conn} -> {:ok, used(%{http | conn: conn, endpoint: endpoint})}
      {:error, error} -> {:error, %{http | conn: nil}, error}
    end
  end

  defp open(endpoint, transport_opts) do
    Mint.HTTP1.connect(endpoint.scheme, endpoint.host, endpoint.port,
      mode: :passive,
      transport_opts: transport_opts
    )
  end

  defp used(http), do: %{http | used_at: System.monotonic_time(:millisecond)}

  defp idle_for(%__MODULE__{used_at: nil}), do: :infinity
  defp idle_for(http), do: System.monotonic_time(:millisecond) - http.used_at

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp receive_response(http, ref, deadline, acc \\ %{status: nil, data: []}) do
    timeout = remaining(deadline)

    case Mint.HTTP1.recv(http.conn, 0, timeout) do
      {:ok, conn, responses} ->
        http = %{http | conn: conn}

        case collect(responses, ref, acc) do
          {:done, %{status: status, data: data}} ->
            {:ok, used(http), status, data |> Enum.reverse() |> IO.iodata_to_binary()}

          {:more, acc} ->
            receive_response(http, ref, deadline, acc)
        end

      {:error, conn, error, _responses} ->
        # The response is incomplete, so this connection cannot take another
        # request.
        {:ok, conn} = Mint.HTTP1.close(conn)
        {:error, %{http | conn: conn}, error}
    end
  end

  defp collect([], _ref, acc), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, acc),
    do: collect(rest, ref, %{acc | status: status})

  defp collect([{:headers, ref, _headers} | rest], ref, acc), do: collect(rest, ref, acc)

  defp collect([{:data, ref, data} | rest], ref, acc),
    do: collect(rest, ref, %{acc | data: [data | acc.data]})

  defp collect([{:done, ref} | _rest], ref, acc), do: {:done, acc}
  defp collect([_other | rest], ref, acc), do: collect(rest, ref, acc)
end

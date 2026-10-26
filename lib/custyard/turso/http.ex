defmodule Custyard.Turso.HTTP do
  @moduledoc """
  One persistent HTTP/1.1 connection, used synchronously.

  Each `Custyard.Turso.Connection` owns one. DBConnection runs its callbacks
  in whichever process checked the connection out, so the socket stays in
  passive mode and the caller reads its own response.
  """

  defstruct [:conn, :endpoint, :connect_timeout]

  @type t :: %__MODULE__{}

  @default_connect_timeout 5_000

  @spec connect(Custyard.Turso.Protocol.endpoint(), keyword) ::
          {:ok, t} | {:error, Exception.t()}
  def connect(endpoint, opts \\ []) do
    timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    http = %__MODULE__{endpoint: endpoint, connect_timeout: timeout}

    with {:ok, conn} <- open(endpoint, timeout), do: {:ok, %{http | conn: conn}}
  end

  @doc """
  POSTs `body` to `path` on `endpoint` and reads the whole response.

  Reconnects first when the server closed the previous connection or the
  request is for another endpoint. A request that fails while being written
  never reached the server complete, so it is sent once more on a fresh
  connection. Once it has been written, a failure is returned as is: the
  server may have run it.
  """
  @spec post(t, Custyard.Turso.Protocol.endpoint(), String.t(), list, iodata, timeout) ::
          {:ok, t, non_neg_integer, binary} | {:error, t, Exception.t()}
  def post(http, endpoint, path, headers, body, timeout) do
    deadline = deadline(timeout)

    with {:ok, http} <- ensure_open(http, endpoint) do
      case Mint.HTTP1.request(http.conn, "POST", path, headers, body) do
        {:ok, conn, ref} ->
          receive_response(%{http | conn: conn}, ref, deadline)

        {:error, conn, _error} ->
          http = %{http | conn: conn}

          with {:ok, http} <- reopen(http, endpoint),
               {:ok, conn, ref} <- request(http, path, headers, body) do
            receive_response(%{http | conn: conn}, ref, deadline)
          end
      end
    end
  end

  @doc """
  Notices a connection the server closed while it sat idle, without a round
  trip, and replaces it.
  """
  @spec check(t) :: {:ok, t} | {:error, t, Exception.t()}
  def check(%__MODULE__{conn: nil} = http), do: reopen(http, http.endpoint)

  def check(%__MODULE__{conn: conn} = http) do
    # A zero timeout returns at once: nothing to read means the connection
    # is still open, and a close the server sent marks it closed.
    conn =
      case Mint.HTTP1.recv(conn, 0, 0) do
        {:ok, conn, _responses} -> conn
        {:error, conn, _error, _responses} -> conn
      end

    ensure_open(%{http | conn: conn}, http.endpoint)
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{conn: nil}), do: :ok

  def close(%__MODULE__{conn: conn}) do
    {:ok, _conn} = Mint.HTTP1.close(conn)
    :ok
  end

  defp request(http, path, headers, body) do
    case Mint.HTTP1.request(http.conn, "POST", path, headers, body) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, conn, error} -> {:error, %{http | conn: conn}, error}
    end
  end

  defp ensure_open(%__MODULE__{conn: conn, endpoint: endpoint} = http, endpoint)
       when conn != nil do
    if Mint.HTTP1.open?(conn), do: {:ok, http}, else: reopen(http, endpoint)
  end

  defp ensure_open(http, endpoint), do: reopen(http, endpoint)

  defp reopen(http, endpoint) do
    close(http)

    case open(endpoint, http.connect_timeout) do
      {:ok, conn} -> {:ok, %{http | conn: conn, endpoint: endpoint}}
      {:error, error} -> {:error, %{http | conn: nil}, error}
    end
  end

  defp open(endpoint, timeout) do
    Mint.HTTP1.connect(endpoint.scheme, endpoint.host, endpoint.port,
      mode: :passive,
      transport_opts: [timeout: timeout]
    )
  end

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
            {:ok, http, status, data |> Enum.reverse() |> IO.iodata_to_binary()}

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

defmodule Custyard.Attachments.ClamAV do
  @moduledoc """
  Bounded ClamAV INSTREAM client. Configure a trusted, private clamd endpoint;
  the protocol has no authentication or transport encryption. File paths are
  never sent to the daemon and no shell command is executed.
  """
  @behaviour Custyard.Attachments.Scanner

  alias Custyard.Attachments.Scanner

  @chunk_bytes 65_536
  @max_reply_bytes 4096

  @impl true
  def scan(bytes, opts) when is_binary(bytes) do
    if byte_size(bytes) <= Scanner.max_bytes() do
      do_scan(bytes, opts)
    else
      {:error, :too_large}
    end
  end

  defp do_scan(bytes, opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.get(opts, :port, 3310)
    timeout = Keyword.get(opts, :timeout, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    socket_opts = [
      :binary,
      active: false,
      packet: :raw,
      send_timeout: timeout,
      send_timeout_close: true
    ]

    case connect(host, port, socket_opts, deadline) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, "zINSTREAM\0"),
               :ok <- send_chunks(socket, bytes, deadline),
               :ok <- :gen_tcp.send(socket, <<0::32>>),
               {:ok, reply} <- receive_reply(socket, deadline, "") do
            parse_reply(reply)
          else
            _ -> {:error, :scanner_unavailable}
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        {:error, :scanner_unavailable}
    end
  rescue
    _ -> {:error, :scanner_unavailable}
  end

  defp connect(host, port, options, deadline) do
    address = String.to_charlist(host)

    # Private service networks may expose IPv6-only names. Preserve one overall
    # deadline while supporting both those endpoints and ordinary IPv4 clamd.
    case :gen_tcp.connect(address, port, [:inet6 | options], remaining(deadline)) do
      {:ok, socket} -> {:ok, socket}
      _ -> :gen_tcp.connect(address, port, [:inet | options], max(remaining(deadline), 0))
    end
  end

  defp send_chunks(_socket, "", _deadline), do: :ok

  defp send_chunks(socket, bytes, deadline) do
    count = min(byte_size(bytes), @chunk_bytes)
    <<chunk::binary-size(count), rest::binary>> = bytes

    with timeout when timeout > 0 <- remaining(deadline),
         :ok <- :inet.setopts(socket, send_timeout: timeout),
         :ok <- :gen_tcp.send(socket, [<<count::32>>, chunk]) do
      send_chunks(socket, rest, deadline)
    else
      _ -> {:error, :timeout}
    end
  end

  defp receive_reply(socket, deadline, accumulated) do
    with timeout when timeout > 0 <- remaining(deadline),
         {:ok, chunk} <- :gen_tcp.recv(socket, 0, timeout),
         reply <- accumulated <> chunk,
         true <- byte_size(reply) <= @max_reply_bytes do
      if String.contains?(reply, <<0>>),
        do: {:ok, reply},
        else: receive_reply(socket, deadline, reply)
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_reply("stream: OK\0"), do: :clean

  defp parse_reply(reply) do
    if String.starts_with?(reply, "stream: ") and String.ends_with?(reply, " FOUND\0"),
      do: :infected,
      else: {:error, :invalid_response}
  end

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)
end

defmodule Custyard.Attachments.ClamAVTest do
  use ExUnit.Case, async: true

  alias Custyard.Attachments.ClamAV

  test "streams bounded length-prefixed chunks and accepts only an exact clean verdict" do
    bytes = :binary.copy("a", 70_000)
    {listener, port} = listener()
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        assert {:ok, "zINSTREAM\0"} = :gen_tcp.recv(socket, 10, 2000)
        received = read_chunks(socket, [])
        send(parent, {:streamed, received})
        :gen_tcp.send(socket, "stream: OK\0")
        :gen_tcp.close(socket)
      end)

    assert ClamAV.scan(bytes, host: "127.0.0.1", port: port, timeout: 2000) == :clean
    assert_receive {:streamed, ^bytes}
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "malware, engine failures and malformed responses fail closed" do
    for {reply, expected} <- [
          {"stream: Eicar-Test-Signature FOUND\0", :infected},
          {"INSTREAM size limit exceeded. ERROR\0", {:error, :invalid_response}},
          {"stream: OK\0ignored", {:error, :invalid_response}},
          {"something OK\0", {:error, :invalid_response}}
        ] do
      assert scan_reply(reply) == expected
    end
  end

  test "oversized responses and interrupted streams are not clean" do
    assert {:error, _} = scan_reply(String.duplicate("x", 4097) <> "\0")
    assert {:error, _} = scan_reply("")
  end

  test "scanner timeout is bounded" do
    {listener, port} = listener()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        assert {:ok, "zINSTREAM\0"} = :gen_tcp.recv(socket, 10, 2000)
        read_chunks(socket, [])
        # Wait for the client to close after its deadline.
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
        :gen_tcp.close(socket)
      end)

    assert {:error, _} = ClamAV.scan("test", host: "127.0.0.1", port: port, timeout: 100)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "connects to private IPv6 endpoints" do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        :inet6,
        active: false,
        packet: :raw,
        ip: {0, 0, 0, 0, 0, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        assert {:ok, "zINSTREAM\0"} = :gen_tcp.recv(socket, 10, 2000)
        read_chunks(socket, [])
        :gen_tcp.send(socket, "stream: OK\0")
        :gen_tcp.close(socket)
      end)

    assert ClamAV.scan("test", host: "::1", port: port, timeout: 2000) == :clean
    Task.await(server)
    :gen_tcp.close(listener)
  end

  defp scan_reply(reply) do
    {listener, port} = listener()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        assert {:ok, "zINSTREAM\0"} = :gen_tcp.recv(socket, 10, 2000)
        read_chunks(socket, [])
        :gen_tcp.send(socket, reply)
        :gen_tcp.close(socket)
      end)

    result = ClamAV.scan("test", host: "127.0.0.1", port: port, timeout: 2000)
    Task.await(server)
    :gen_tcp.close(listener)
    result
  end

  defp listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listener)
    {listener, port}
  end

  defp read_chunks(socket, chunks) do
    assert {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4, 2000)

    if size == 0 do
      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    else
      assert size <= 65_536
      assert {:ok, chunk} = :gen_tcp.recv(socket, size, 2000)
      read_chunks(socket, [chunk | chunks])
    end
  end
end

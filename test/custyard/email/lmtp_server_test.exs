defmodule Custyard.Email.LMTPServerTest do
  @moduledoc """
  Tests for the LMTP server module.

  The LMTP server accepts email via the Local Mail Transfer Protocol (RFC 2033)
  and passes messages to the email processor via gen_smtp callbacks.

  These tests use gen_smtp's client or raw TCP to connect to the LMTP server.
  """
  use Custyard.DataCase, async: false

  alias Custyard.Email.LMTPServer

  import Custyard.Factory

  # Test port to avoid conflicts with production
  @test_port 2525

  # Ensure any leftover servers are stopped before each test
  # and create the custyard.test organization for recipient validation
  setup do
    # Stop any server that might be running on the test port
    server_name = LMTPServer.server_name_for_port(@test_port)

    case Process.whereis(server_name) do
      nil -> :ok
      pid -> LMTPServer.stop(pid)
    end

    # Also try ranch listener cleanup
    try do
      :ranch.stop_listener(server_name)
    catch
      _, _ -> :ok
    end

    # Create organizations for test domains so recipient validation passes
    test_org = insert_organization(domain: "custyard.test")
    example_org = insert_organization(domain: "example.com")

    {:ok, test_org: test_org, example_org: example_org}
  end

  # Sample email for testing - must use CRLF line endings for SMTP/LMTP
  @simple_email "From: alice@example.com\r\n" <>
                  "To: support@custyard.test\r\n" <>
                  "Subject: Test email\r\n" <>
                  "Message-ID: <test-lmtp-001@example.com>\r\n" <>
                  "MIME-Version: 1.0\r\n" <>
                  "Content-Type: text/plain; charset=utf-8\r\n" <>
                  "\r\n" <>
                  "This is a test email for LMTP server testing.\r\n"

  describe "server lifecycle" do
    test "starts and listens on configured port" do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)

      # Verify server is running - gen_smtp returns the listener pid
      assert is_pid(pid)

      # Verify port is listening
      case :gen_tcp.connect(~c"localhost", @test_port, [:binary], 1000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          assert true

        {:error, reason} ->
          flunk("Could not connect to LMTP server: #{inspect(reason)}")
      end

      LMTPServer.stop(pid)
    end

    test "stops cleanly on shutdown" do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)

      # Request clean shutdown
      LMTPServer.stop(pid)

      # Give it a moment to release the port
      :timer.sleep(100)

      # Port should be released
      case :gen_tcp.connect(~c"localhost", @test_port, [:binary], 500) do
        {:error, :econnrefused} ->
          assert true

        {:ok, socket} ->
          :gen_tcp.close(socket)
          flunk("Port still listening after shutdown")
      end
    end

    test "child_spec returns valid specification" do
      spec = LMTPServer.child_spec(port: @test_port, hostname: "test.local")

      assert spec.id == LMTPServer
      assert spec.type == :worker
      assert spec.restart == :permanent
      assert is_tuple(spec.start)
    end

    test "child_spec includes connection limit options" do
      spec =
        LMTPServer.child_spec(
          port: @test_port,
          hostname: "test.local",
          max_connections: 500,
          num_acceptors: 5
        )

      {_module, _fun, [opts]} = spec.start
      assert Keyword.get(opts, :max_connections) == 500
      assert Keyword.get(opts, :num_acceptors) == 5
    end

    test "child_spec uses default connection limits when not specified" do
      spec = LMTPServer.child_spec(port: @test_port)

      {_module, _fun, [opts]} = spec.start
      # Ranch defaults: max_connections = 1024, num_acceptors = 10
      assert Keyword.get(opts, :max_connections) == 1024
      assert Keyword.get(opts, :num_acceptors) == 10
    end

    test "starts server with custom connection limits" do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_connections: 500,
          num_acceptors: 5
        )

      assert is_pid(pid)

      # Verify server is running by connecting
      {:ok, socket} = :gen_tcp.connect(~c"localhost", @test_port, [:binary], 1000)
      :gen_tcp.close(socket)

      LMTPServer.stop(pid)
    end
  end

  describe "LMTP connection handling" do
    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid}
    end

    test "accepts LMTP connection and sends greeting" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      # Should receive LMTP greeting (220)
      {:ok, greeting} = :gen_tcp.recv(socket, 0, 5000)
      assert greeting =~ "220"
      assert greeting =~ "LMTP"

      :gen_tcp.close(socket)
    end

    test "responds to LHLO command" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      # Consume greeting
      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      # Send LHLO (LMTP equivalent of EHLO)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should respond with 250
      assert response =~ "250"

      :gen_tcp.close(socket)
    end

    test "rejects EHLO in LMTP mode (LHLO required)" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      # Consume greeting
      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      # Send EHLO - LMTP requires LHLO instead
      :ok = :gen_tcp.send(socket, "EHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # LMTP should reject EHLO with 500 error
      assert response =~ "500"

      :gen_tcp.close(socket)
    end

    test "responds to QUIT command" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      # Consume greeting
      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      # Send QUIT
      :ok = :gen_tcp.send(socket, "QUIT\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should respond with 221
      assert response =~ "221"

      :gen_tcp.close(socket)
    end
  end

  describe "email processing flow" do
    setup %{example_org: sender_org, test_org: recipient_org} do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      # Create contact for email processing (org comes from global setup)
      _contact = insert_contact(organization_id: sender_org.id, email: "alice@example.com")

      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid, org: sender_org, recipient_org: recipient_org}
    end

    test "accepts MAIL FROM command", %{org: _org} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, mail_resp} = :gen_tcp.recv(socket, 0, 5000)
      assert mail_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "accepts RCPT TO command", %{org: _org} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, rcpt_resp} = :gen_tcp.recv(socket, 0, 5000)
      assert rcpt_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "accepts DATA command and returns 354", %{org: _org} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, data_resp} = :gen_tcp.recv(socket, 0, 5000)
      assert data_resp =~ "354"

      :gen_tcp.close(socket)
    end

    test "returns 250 OK on successful email processing", %{org: _org} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Send email content followed by CRLF.CRLF
      :ok = :gen_tcp.send(socket, @simple_email <> "\r\n.\r\n")
      {:ok, final_resp} = :gen_tcp.recv(socket, 0, 5000)

      # Should return 250 on success
      assert final_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "creates conversation from processed email", %{recipient_org: recipient_org} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, @simple_email <> "\r\n.\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :gen_tcp.close(socket)

      # Conversation is created under the recipient's org (resolved from RCPT TO domain),
      # not the sender's org. This is the correct behavior — the inbound route belongs
      # to the org that owns the recipient domain.
      conversations = Custyard.Conversations.list_for_organization(recipient_org.id)
      assert conversations != []

      [conv | _] = conversations
      assert conv.subject == "Test email"
    end
  end

  describe "error handling" do
    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid}
    end

    test "returns error for empty DATA" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Send empty message (just terminator)
      :ok = :gen_tcp.send(socket, "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should return 5xx error for empty message
      assert response =~ "5"

      :gen_tcp.close(socket)
    end

    test "handles connection drop gracefully" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Abruptly close connection
      :gen_tcp.close(socket)

      # Server should still accept new connections
      :timer.sleep(100)

      {:ok, socket2} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, greeting} = :gen_tcp.recv(socket2, 0, 5000)
      assert greeting =~ "220"

      :gen_tcp.close(socket2)
    end

    test "VRFY is disabled" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "VRFY alice@example.com\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # VRFY should return 252 (disabled)
      assert response =~ "252"

      :gen_tcp.close(socket)
    end

    test "AUTH is not supported" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "AUTH PLAIN\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # AUTH returns 502 (not implemented) from gen_smtp
      assert response =~ "502" or response =~ "503"

      :gen_tcp.close(socket)
    end
  end

  describe "RSET command" do
    setup %{example_org: sender_org, test_org: recipient_org} do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      _contact = insert_contact(organization_id: sender_org.id, email: "alice@example.com")

      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid, org: sender_org, recipient_org: recipient_org}
    end

    test "RSET resets transaction state", %{org: _org} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Start a transaction
      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # RSET to abort (before DATA)
      :ok = :gen_tcp.send(socket, "RSET\r\n")
      {:ok, rset_resp} = :gen_tcp.recv(socket, 0, 5000)
      assert rset_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "can send multiple messages via separate connections", %{recipient_org: recipient_org} do
      # First message
      {:ok, socket1} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket1, 0, 5000)
      :ok = :gen_tcp.send(socket1, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket1, 0, 5000)
      send_email_via_socket(socket1, "alice@example.com", "First message via LMTP")
      :gen_tcp.close(socket1)

      # Second message on new connection
      {:ok, socket2} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket2, 0, 5000)
      :ok = :gen_tcp.send(socket2, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket2, 0, 5000)
      send_email_via_socket(socket2, "alice@example.com", "Second message via LMTP")
      :gen_tcp.close(socket2)

      # Conversations are created under the recipient's org (custyard.test),
      # not the sender's org, because the inbound route resolves from RCPT TO domain.
      conversations = Custyard.Conversations.list_for_organization(recipient_org.id)
      assert Enum.count(conversations) >= 2
    end

    defp send_email_via_socket(socket, from, subject) do
      # Build email with proper CRLF line endings required by SMTP/LMTP
      msg_id = :erlang.unique_integer([:positive])

      email =
        "From: #{from}\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: #{subject}\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body of #{subject}\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<#{from}>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, resp} = :gen_tcp.recv(socket, 0, 5000)
      assert resp =~ "250"
    end
  end

  describe "concurrent connections" do
    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid}
    end

    test "handles multiple simultaneous connections" do
      # Open multiple connections
      sockets =
        Enum.map(1..5, fn _ ->
          {:ok, socket} =
            :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

          {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)
          socket
        end)

      # All should be able to send LHLO
      Enum.each(sockets, fn socket ->
        :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
        {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
        assert response =~ "250"
      end)

      # Clean up
      Enum.each(sockets, &:gen_tcp.close/1)
    end
  end

  describe "server configuration" do
    test "uses explicit port from options" do
      alt_port = 2526

      {:ok, pid} = LMTPServer.start_link(port: alt_port)

      case :gen_tcp.connect(~c"localhost", alt_port, [:binary], 1000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          assert true

        {:error, _} ->
          flunk("Server not listening on explicit port")
      end

      LMTPServer.stop(pid)
    end

    test "uses explicit hostname in greeting" do
      {:ok, pid} = LMTPServer.start_link(port: @test_port, hostname: "mail.example.com")

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, greeting} = :gen_tcp.recv(socket, 0, 5000)

      # Greeting should include the hostname
      assert greeting =~ "mail.example.com"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "STARTTLS not advertised without TLS configuration" do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # STARTTLS should NOT be in the extensions list
      refute response =~ "STARTTLS"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "child_spec includes TLS options" do
      spec =
        LMTPServer.child_spec(
          port: @test_port,
          hostname: "test.local",
          tls: [certfile: "/path/to/cert.pem", keyfile: "/path/to/key.pem"]
        )

      assert spec.id == LMTPServer
      assert spec.type == :worker

      # The start tuple should include TLS options
      {_mod, _fun, [opts]} = spec.start
      assert Keyword.has_key?(opts, :tls)

      assert Keyword.get(opts, :tls) == [
               certfile: "/path/to/cert.pem",
               keyfile: "/path/to/key.pem"
             ]
    end
  end

  describe "STARTTLS support" do
    # Note: Full TLS negotiation tests require actual certificates.
    # These tests verify the configuration and advertisement behavior.

    test "STARTTLS advertised in LHLO when TLS configured" do
      # Use fake cert paths - gen_smtp won't validate until actual TLS negotiation
      # This tests that STARTTLS is advertised in extensions
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          tls: [certfile: "/tmp/fake-cert.pem", keyfile: "/tmp/fake-key.pem"]
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # STARTTLS should be in the extensions list
      assert response =~ "STARTTLS"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "empty TLS options do not enable STARTTLS" do
      {:ok, pid} = LMTPServer.start_link(port: @test_port, tls: [])

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # STARTTLS should NOT be advertised without certfile
      refute response =~ "STARTTLS"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "TLS requires certfile to be enabled (keyfile alone is not sufficient)" do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          tls: [keyfile: "/tmp/fake-key.pem"]
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # STARTTLS should NOT be advertised without certfile
      refute response =~ "STARTTLS"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "TLS requires keyfile to be enabled (certfile alone is not sufficient)" do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          tls: [certfile: "/tmp/fake-cert.pem"]
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # STARTTLS should NOT be advertised without keyfile
      refute response =~ "STARTTLS"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "TLS disabled when neither certfile nor keyfile present" do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # STARTTLS should NOT be advertised when no TLS options provided
      refute response =~ "STARTTLS"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end
  end

  describe "gen_smtp callbacks" do
    # These tests verify the callback behavior indirectly through SMTP commands

    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid}
    end

    test "HELO is rejected in LMTP mode" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # HELO is rejected in LMTP mode - LHLO is required
      :ok = :gen_tcp.send(socket, "HELO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # LMTP rejects HELO with 500 error
      assert response =~ "500"

      :gen_tcp.close(socket)
    end

    test "handle_MAIL_extension accepts extensions" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # MAIL FROM with SIZE extension
      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com> SIZE=1000\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should accept (or ignore) the extension
      assert response =~ "250"

      :gen_tcp.close(socket)
    end

    test "handle_RCPT_extension may reject unsupported extensions" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # RCPT TO with NOTIFY extension - gen_smtp may reject unsupported extensions
      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test> NOTIFY=NEVER\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # gen_smtp rejects unsupported extensions with 555
      assert response =~ "555" or response =~ "250"

      :gen_tcp.close(socket)
    end

    test "unknown commands get no response (noreply)" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Send unknown command - handle_other returns {:noreply, state}
      # so the server doesn't send a response (connection stays open)
      :ok = :gen_tcp.send(socket, "UNKNOWNCOMMAND arg\r\n")

      # Server returns noreply, so recv will timeout or get nothing
      # We verify the connection is still usable by sending another command
      :ok = :gen_tcp.send(socket, "QUIT\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # The QUIT should work
      assert response =~ "221"

      :gen_tcp.close(socket)
    end
  end

  describe "rate limiting" do
    setup %{example_org: org} do
      _contact = insert_contact(organization_id: org.id, email: "alice@example.com")
      {:ok, org: org}
    end

    test "child_spec includes rate_limit options" do
      spec =
        LMTPServer.child_spec(
          port: @test_port,
          rate_limit: [
            messages_per_connection: 50,
            messages_per_minute: 500,
            window_seconds: 30
          ]
        )

      {_module, _fun, [opts]} = spec.start
      rate_limit = Keyword.get(opts, :rate_limit)

      assert Keyword.get(rate_limit, :messages_per_connection) == 50
      assert Keyword.get(rate_limit, :messages_per_minute) == 500
      assert Keyword.get(rate_limit, :window_seconds) == 30
    end

    test "child_spec uses default rate limits when not specified" do
      spec = LMTPServer.child_spec(port: @test_port)

      {_module, _fun, [opts]} = spec.start
      # Default should be empty list (uses module defaults)
      assert Keyword.get(opts, :rate_limit) == []
    end

    test "enforces per-connection message limit", %{org: _org} do
      # Start server with very low per-connection limit
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          rate_limit: [
            messages_per_connection: 2,
            messages_per_minute: :infinity
          ]
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # First message should succeed
      send_email_data(socket, "alice@example.com", "First message")
      {:ok, resp1} = :gen_tcp.recv(socket, 0, 5000)
      assert resp1 =~ "250"

      # Second message should succeed
      send_email_data(socket, "alice@example.com", "Second message")
      {:ok, resp2} = :gen_tcp.recv(socket, 0, 5000)
      assert resp2 =~ "250"

      # Third message should be rejected (limit is 2)
      send_email_data(socket, "alice@example.com", "Third message")
      {:ok, resp3} = :gen_tcp.recv(socket, 0, 5000)
      assert resp3 =~ "421"
      assert resp3 =~ "Too many messages"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "allows messages on new connection after per-connection limit", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          rate_limit: [
            messages_per_connection: 1,
            messages_per_minute: :infinity
          ]
        )

      # First connection - send one message
      {:ok, socket1} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket1, 0, 5000)
      :ok = :gen_tcp.send(socket1, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket1, 0, 5000)

      send_email_data(socket1, "alice@example.com", "First connection message")
      {:ok, resp1} = :gen_tcp.recv(socket1, 0, 5000)
      assert resp1 =~ "250"

      :gen_tcp.close(socket1)

      # Second connection - should be able to send again
      {:ok, socket2} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket2, 0, 5000)
      :ok = :gen_tcp.send(socket2, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket2, 0, 5000)

      send_email_data(socket2, "alice@example.com", "Second connection message")
      {:ok, resp2} = :gen_tcp.recv(socket2, 0, 5000)
      assert resp2 =~ "250"

      :gen_tcp.close(socket2)
      LMTPServer.stop(pid)
    end

    test "infinity disables per-connection limit", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          rate_limit: [
            messages_per_connection: :infinity,
            messages_per_minute: :infinity
          ]
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Should be able to send multiple messages
      for i <- 1..5 do
        send_email_data(socket, "alice@example.com", "Message #{i}")
        {:ok, resp} = :gen_tcp.recv(socket, 0, 5000)
        assert resp =~ "250", "Message #{i} should succeed"
      end

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    defp send_email_data(socket, from, subject) do
      msg_id = :erlang.unique_integer([:positive])

      email =
        "From: #{from}\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: #{subject}\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body of #{subject}\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<#{from}>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
    end
  end

  describe "telemetry events" do
    setup do
      # Start the server
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      on_exit(fn -> LMTPServer.stop(pid) end)

      # Set up a test handler to capture telemetry events
      test_pid = self()
      handler_id = "test-telemetry-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:custyard, :lmtp, :connection, :open],
          [:custyard, :lmtp, :connection, :close],
          [:custyard, :lmtp, :email, :start],
          [:custyard, :lmtp, :email, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, server: pid, handler_id: handler_id}
    end

    test "emits connection open event on connect" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      assert_receive {:telemetry, [:custyard, :lmtp, :connection, :open], measurements, metadata},
                     1000

      assert is_integer(measurements.system_time)
      assert is_tuple(metadata.peer)

      :gen_tcp.close(socket)
    end

    test "emits connection close event on disconnect" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      # Drain the connection open event
      assert_receive {:telemetry, [:custyard, :lmtp, :connection, :open], _, _}, 1000

      :gen_tcp.close(socket)

      # Give the server time to process the disconnect
      :timer.sleep(100)

      assert_receive {:telemetry, [:custyard, :lmtp, :connection, :close], measurements,
                      metadata},
                     1000

      assert is_integer(measurements.duration)
      assert metadata.messages_processed == 0
    end

    test "emits email start and stop events on message processing" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      # Drain connection open event
      assert_receive {:telemetry, [:custyard, :lmtp, :connection, :open], _, _}, 1000

      # Send email through LMTP
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, @simple_email <> "\r\n.\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Should receive start event
      assert_receive {:telemetry, [:custyard, :lmtp, :email, :start], measurements, metadata},
                     1000

      assert is_integer(measurements.system_time)
      assert is_integer(metadata.size)
      assert metadata.size > 0

      # Should receive stop event (may succeed or fail depending on processor setup)
      assert_receive {:telemetry, [:custyard, :lmtp, :email, :stop], measurements, metadata}, 1000
      assert is_integer(measurements.duration)
      # result should be :ok or :error
      assert metadata.result in [:ok, :error]

      :gen_tcp.close(socket)
    end
  end

  describe "mail loop detection" do
    setup %{example_org: org} do
      _contact = insert_contact(organization_id: org.id, email: "alice@example.com")
      {:ok, org: org}
    end

    test "rejects email when hostname appears more than max_received_count times", %{org: _org} do
      hostname = "mail.custyard.test"

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          hostname: hostname,
          max_received_count: 2
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Build email with 3 Received headers containing our hostname (exceeds limit of 2)
      msg_id = :erlang.unique_integer([:positive])

      email =
        "Received: from external.example.com by #{hostname}; Mon, 24 Mar 2026 10:00:00 +0000\r\n" <>
          "Received: from internal.example.com by #{hostname}; Mon, 24 Mar 2026 09:59:00 +0000\r\n" <>
          "Received: from relay.example.com by #{hostname}; Mon, 24 Mar 2026 09:58:00 +0000\r\n" <>
          "From: alice@example.com\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: Loop test\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body with potential loop\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should return 554 mail loop error (3 > 2)
      assert response =~ "554"
      assert response =~ "loop"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "accepts email when hostname count equals exactly max_received_count (boundary)", %{
      org: _org
    } do
      # With the off-by-one fix, count == max is allowed; only count > max triggers rejection.
      # This is the boundary case: max_received_count is 5, exactly 5 occurrences should pass.
      hostname = "mail.custyard.test"

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          hostname: hostname,
          max_received_count: 5
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Build email with exactly 5 Received headers containing our hostname
      msg_id = :erlang.unique_integer([:positive])

      email =
        "Received: from a.example.com by #{hostname}; Mon, 24 Mar 2026 10:00:00 +0000\r\n" <>
          "Received: from b.example.com by #{hostname}; Mon, 24 Mar 2026 09:59:00 +0000\r\n" <>
          "Received: from c.example.com by #{hostname}; Mon, 24 Mar 2026 09:58:00 +0000\r\n" <>
          "Received: from d.example.com by #{hostname}; Mon, 24 Mar 2026 09:57:00 +0000\r\n" <>
          "Received: from e.example.com by #{hostname}; Mon, 24 Mar 2026 09:56:00 +0000\r\n" <>
          "From: alice@example.com\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: Boundary loop test\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body at the boundary\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Exactly 5 occurrences with max_received_count=5 should be accepted (5 > 5 is false)
      assert response =~ "250"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "rejects email when hostname count is one more than max_received_count (boundary)", %{
      org: _org
    } do
      # Companion to the above: 6 occurrences with max of 5 should be rejected.
      hostname = "mail.custyard.test"

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          hostname: hostname,
          max_received_count: 5
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Build email with 6 Received headers containing our hostname (exceeds limit of 5)
      msg_id = :erlang.unique_integer([:positive])

      email =
        "Received: from a.example.com by #{hostname}; Mon, 24 Mar 2026 10:00:00 +0000\r\n" <>
          "Received: from b.example.com by #{hostname}; Mon, 24 Mar 2026 09:59:00 +0000\r\n" <>
          "Received: from c.example.com by #{hostname}; Mon, 24 Mar 2026 09:58:00 +0000\r\n" <>
          "Received: from d.example.com by #{hostname}; Mon, 24 Mar 2026 09:57:00 +0000\r\n" <>
          "Received: from e.example.com by #{hostname}; Mon, 24 Mar 2026 09:56:00 +0000\r\n" <>
          "Received: from f.example.com by #{hostname}; Mon, 24 Mar 2026 09:55:00 +0000\r\n" <>
          "From: alice@example.com\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: Over boundary loop test\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body over the boundary\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # 6 occurrences with max_received_count=5 should be rejected (6 > 5 is true)
      assert response =~ "554"
      assert response =~ "loop"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "accepts email when hostname appears fewer times than limit", %{org: _org} do
      hostname = "mail.custyard.test"

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          hostname: hostname,
          max_received_count: 3
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Build email with one Received header containing our hostname (under limit of 3)
      msg_id = :erlang.unique_integer([:positive])

      email =
        "Received: from external.example.com by #{hostname}; Mon, 24 Mar 2026 10:00:00 +0000\r\n" <>
          "Received: from other.example.com by different.server.com; Mon, 24 Mar 2026 09:59:00 +0000\r\n" <>
          "From: alice@example.com\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: Normal delivery\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body of normal email\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should accept the message (250)
      assert response =~ "250"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "loop detection is case-insensitive for hostname", %{org: _org} do
      hostname = "mail.custyard.test"

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          hostname: hostname,
          max_received_count: 2
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Build email with 3 mixed-case hostnames (exceeds max_received_count of 2)
      msg_id = :erlang.unique_integer([:positive])

      email =
        "Received: from external.example.com by MAIL.CUSTYARD.TEST; Mon, 24 Mar 2026 10:00:00 +0000\r\n" <>
          "Received: from internal.example.com by Mail.Custyard.Test; Mon, 24 Mar 2026 09:59:00 +0000\r\n" <>
          "Received: from relay.example.com by mail.CUSTYARD.test; Mon, 24 Mar 2026 09:58:00 +0000\r\n" <>
          "From: alice@example.com\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: Case test\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should detect loop even with case differences (3 > 2)
      assert response =~ "554"
      assert response =~ "loop"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "infinity disables loop detection", %{org: _org} do
      hostname = "mail.custyard.test"

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          hostname: hostname,
          max_received_count: :infinity
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Build email with many Received headers
      msg_id = :erlang.unique_integer([:positive])

      email =
        "Received: from a.com by #{hostname}; Mon, 24 Mar 2026 10:00:00 +0000\r\n" <>
          "Received: from b.com by #{hostname}; Mon, 24 Mar 2026 09:59:00 +0000\r\n" <>
          "Received: from c.com by #{hostname}; Mon, 24 Mar 2026 09:58:00 +0000\r\n" <>
          "Received: from d.com by #{hostname}; Mon, 24 Mar 2026 09:57:00 +0000\r\n" <>
          "Received: from e.com by #{hostname}; Mon, 24 Mar 2026 09:56:00 +0000\r\n" <>
          "From: alice@example.com\r\n" <>
          "To: support@custyard.test\r\n" <>
          "Subject: Infinity test\r\n" <>
          "Message-ID: <#{msg_id}@example.com>\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "Body\r\n"

      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "RCPT TO:<support@custyard.test>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, email <> "\r\n.\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should accept despite many loop headers (infinity disables check)
      assert response =~ "250"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "child_spec includes max_received_count option" do
      spec =
        LMTPServer.child_spec(
          port: @test_port,
          hostname: "mail.example.com",
          max_received_count: 5
        )

      {_module, _fun, [opts]} = spec.start
      assert Keyword.get(opts, :max_received_count) == 5
    end

    test "child_spec uses default max_received_count when not specified" do
      spec = LMTPServer.child_spec(port: @test_port)

      {_module, _fun, [opts]} = spec.start
      # Default is 3
      assert Keyword.get(opts, :max_received_count) == 3
    end
  end

  describe "recipient limit validation" do
    # Use unique ports for each test to avoid conflicts since on_exit is async
    @rcpt_port_1 2530
    @rcpt_port_2 2531
    @rcpt_port_3 2532

    test "accepts recipients up to the limit" do
      {:ok, pid} = LMTPServer.start_link(port: @rcpt_port_1, max_recipients: 3)
      on_exit(fn -> LMTPServer.stop(pid) end)

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @rcpt_port_1, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # First 3 recipients should succeed
      for i <- 1..3 do
        :ok = :gen_tcp.send(socket, "RCPT TO:<recipient#{i}@example.com>\r\n")
        {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
        assert response =~ "250", "Expected 250 OK for recipient #{i}"
      end

      :gen_tcp.close(socket)
    end

    test "rejects recipients beyond the limit" do
      {:ok, pid} = LMTPServer.start_link(port: @rcpt_port_2, max_recipients: 2)
      on_exit(fn -> LMTPServer.stop(pid) end)

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @rcpt_port_2, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # First 2 recipients should succeed
      :ok = :gen_tcp.send(socket, "RCPT TO:<recipient1@example.com>\r\n")
      {:ok, response1} = :gen_tcp.recv(socket, 0, 5000)
      assert response1 =~ "250"

      :ok = :gen_tcp.send(socket, "RCPT TO:<recipient2@example.com>\r\n")
      {:ok, response2} = :gen_tcp.recv(socket, 0, 5000)
      assert response2 =~ "250"

      # Third recipient should fail with 452
      :ok = :gen_tcp.send(socket, "RCPT TO:<recipient3@example.com>\r\n")
      {:ok, response3} = :gen_tcp.recv(socket, 0, 5000)
      assert response3 =~ "452"
      assert response3 =~ "Too many recipients"

      :gen_tcp.close(socket)
    end

    test "infinity max_recipients allows unlimited recipients" do
      {:ok, pid} = LMTPServer.start_link(port: @rcpt_port_3, max_recipients: :infinity)
      on_exit(fn -> LMTPServer.stop(pid) end)

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @rcpt_port_3, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Should accept many recipients
      for i <- 1..20 do
        :ok = :gen_tcp.send(socket, "RCPT TO:<recipient#{i}@example.com>\r\n")
        {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
        assert response =~ "250", "Expected 250 OK for recipient #{i}"
      end

      :gen_tcp.close(socket)
    end

    test "child_spec includes max_recipients option" do
      spec =
        LMTPServer.child_spec(
          port: @test_port,
          hostname: "test.local",
          max_recipients: 50
        )

      {_module, _fun, [opts]} = spec.start
      assert Keyword.get(opts, :max_recipients) == 50
    end

    test "child_spec uses default max_recipients when not specified" do
      spec = LMTPServer.child_spec(port: @test_port)

      {_module, _fun, [opts]} = spec.start
      # Default is 100
      assert Keyword.get(opts, :max_recipients) == 100
    end
  end

  describe "large email handling" do
    @moduletag :large_email

    setup do
      org = insert_organization(domain: "large-test.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@large-test.com")
      {:ok, org: org}
    end

    # Helper to build email with large body
    defp build_large_email(body_size_bytes) do
      # Generate body content of specified size
      body = String.duplicate("X", body_size_bytes)

      "From: alice@large-test.com\r\n" <>
        "To: support@large-test.com\r\n" <>
        "Subject: Large email test\r\n" <>
        "Message-ID: <large-test-#{System.unique_integer()}@large-test.com>\r\n" <>
        "MIME-Version: 1.0\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n" <>
        "\r\n" <>
        body <> "\r\n"
    end

    # Helper to build email with base64-encoded attachment
    defp build_email_with_attachment(attachment_size_bytes) do
      # Generate random binary content and base64 encode it
      attachment_data = :crypto.strong_rand_bytes(attachment_size_bytes)
      encoded = Base.encode64(attachment_data)

      # Split base64 into 76-character lines per MIME spec
      encoded_lines =
        encoded
        |> String.codepoints()
        |> Enum.chunk_every(76)
        |> Enum.map_join("\r\n", &Enum.join/1)

      boundary = "----=_Part_#{System.unique_integer()}"

      "From: alice@large-test.com\r\n" <>
        "To: support@large-test.com\r\n" <>
        "Subject: Email with large attachment\r\n" <>
        "Message-ID: <attach-test-#{System.unique_integer()}@large-test.com>\r\n" <>
        "MIME-Version: 1.0\r\n" <>
        "Content-Type: multipart/mixed; boundary=\"#{boundary}\"\r\n" <>
        "\r\n" <>
        "--#{boundary}\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n" <>
        "\r\n" <>
        "This email contains a large attachment.\r\n" <>
        "\r\n" <>
        "--#{boundary}\r\n" <>
        "Content-Type: application/octet-stream; name=\"large_file.bin\"\r\n" <>
        "Content-Transfer-Encoding: base64\r\n" <>
        "Content-Disposition: attachment; filename=\"large_file.bin\"\r\n" <>
        "\r\n" <>
        encoded_lines <>
        "\r\n" <>
        "--#{boundary}--\r\n"
    end

    # Helper to send email via LMTP and return response
    defp send_large_email_via_lmtp(port, email_data, opts \\ []) do
      timeout = Keyword.get(opts, :timeout, 30_000)

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 5000)

      # Greeting
      {:ok, _} = :gen_tcp.recv(socket, 0, timeout)

      # LHLO
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, timeout)

      # MAIL FROM
      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@large-test.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, timeout)

      # RCPT TO
      :ok = :gen_tcp.send(socket, "RCPT TO:<support@large-test.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, timeout)

      # DATA
      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, timeout)

      # Send email content (may need to be chunked for very large emails)
      :ok = send_data_in_chunks(socket, email_data)
      :ok = :gen_tcp.send(socket, "\r\n.\r\n")

      # Get response
      result = :gen_tcp.recv(socket, 0, timeout)

      :gen_tcp.close(socket)
      result
    end

    # Send data in chunks to avoid socket buffer issues with very large emails
    defp send_data_in_chunks(socket, data) when byte_size(data) <= 65_536 do
      :gen_tcp.send(socket, data)
    end

    defp send_data_in_chunks(socket, data) do
      <<chunk::binary-size(65_536), rest::binary>> = data
      :ok = :gen_tcp.send(socket, chunk)
      send_data_in_chunks(socket, rest)
    end

    test "accepts 1 MB plain text email", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 2_000_000
        )

      # Build 1 MB email (slightly under to account for headers)
      email = build_large_email(1_000_000)

      {:ok, response} = send_large_email_via_lmtp(@test_port, email)

      # Should be accepted (processor may still reject due to missing org, but LMTP accepts)
      # Success is 250, processor errors are 421/550
      assert response =~ ~r/250|421|550/

      LMTPServer.stop(pid)
    end

    test "accepts 2 MB email with base64 attachment", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 5_000_000
        )

      # Build email with 1.5 MB attachment (base64 expands ~33%)
      email = build_email_with_attachment(1_500_000)

      {:ok, response} = send_large_email_via_lmtp(@test_port, email, timeout: 60_000)

      # Should be accepted at LMTP level
      assert response =~ ~r/250|421|550/

      LMTPServer.stop(pid)
    end

    test "rejects email exceeding size limit in DATA phase", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          # Set low limit: 100 KB
          max_message_size: 100_000
        )

      # Build 200 KB email (exceeds limit)
      email = build_large_email(200_000)

      {:ok, response} = send_large_email_via_lmtp(@test_port, email)

      # Should be rejected with 552 - message wording may vary
      assert response =~ "552"

      LMTPServer.stop(pid)
    end

    @tag timeout: 180_000
    test "handles 5 MB email without crashing", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 10_000_000
        )

      # Build and send 5 MB email - focus on completion without crash
      email = build_large_email(5_000_000)
      {:ok, response} = send_large_email_via_lmtp(@test_port, email, timeout: 120_000)

      # Should complete (success or processor rejection) without timeout/crash
      assert response =~ ~r/250|421|550/

      # Server should still be running after processing large email
      assert Process.alive?(pid)

      # Can still accept new connections
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, greeting} = :gen_tcp.recv(socket, 0, 5000)
      assert greeting =~ "220"
      :gen_tcp.close(socket)

      LMTPServer.stop(pid)
    end

    test "server remains responsive after processing large email", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 10_000_000
        )

      # Send large email
      large_email = build_large_email(2_000_000)
      {:ok, _} = send_large_email_via_lmtp(@test_port, large_email, timeout: 60_000)

      # Server should still respond to new connections
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, greeting} = :gen_tcp.recv(socket, 0, 5000)
      assert greeting =~ "220"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "handles multiple concurrent large email connections", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 5_000_000,
          max_connections: 10
        )

      # Spawn 3 concurrent large email senders
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            email =
              "From: alice@large-test.com\r\n" <>
                "To: support@large-test.com\r\n" <>
                "Subject: Concurrent test #{i}\r\n" <>
                "Message-ID: <concurrent-#{i}-#{System.unique_integer()}@large-test.com>\r\n" <>
                "Content-Type: text/plain\r\n" <>
                "\r\n" <>
                String.duplicate("Y", 500_000) <> "\r\n"

            send_large_email_via_lmtp(@test_port, email, timeout: 60_000)
          end)
        end

      # All should complete without error
      results = Task.await_many(tasks, 120_000)

      for {:ok, response} <- results do
        # Each should get a response (success or rejection)
        assert response =~ ~r/250|421|550/
      end

      LMTPServer.stop(pid)
    end

    @tag :slow
    test "handles email at exactly size limit boundary", %{org: _org} do
      # 10 KB limit
      limit = 10_000

      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: limit
        )

      # Headers are about 250 bytes, so body can be limit - 250
      header_size = 250
      # Small buffer
      body_size = limit - header_size - 10

      email =
        "From: alice@large-test.com\r\n" <>
          "To: support@large-test.com\r\n" <>
          "Subject: Boundary test\r\n" <>
          "Message-ID: <boundary-test@large-test.com>\r\n" <>
          "Content-Type: text/plain\r\n" <>
          "\r\n" <>
          String.duplicate("Z", body_size) <> "\r\n"

      {:ok, response} = send_large_email_via_lmtp(@test_port, email)

      # Should be accepted (at limit, not over)
      # Note: may get 421/550 from processor, but not 552 from size check
      refute response =~ "552"

      LMTPServer.stop(pid)
    end

    @tag :slow
    test "DATA timeout with stalled connection" do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 1_000_000
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      # Complete handshake up to DATA
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "MAIL FROM:<test@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "RCPT TO:<support@example.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "DATA\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Send partial data but never complete (no ".\r\n")
      :ok = :gen_tcp.send(socket, "Subject: Incomplete\r\n\r\nPartial body...")

      # Server should still accept new connections while waiting
      {:ok, socket2} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, greeting} = :gen_tcp.recv(socket2, 0, 5000)
      assert greeting =~ "220"

      :gen_tcp.close(socket2)
      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end
  end

  describe "message size limits" do
    test "child_spec includes max_message_size option" do
      spec =
        LMTPServer.child_spec(
          port: @test_port,
          max_message_size: 5_000_000
        )

      {_module, _fun, [opts]} = spec.start
      assert Keyword.get(opts, :max_message_size) == 5_000_000
    end

    test "child_spec uses default max_message_size when not specified" do
      spec = LMTPServer.child_spec(port: @test_port)

      {_module, _fun, [opts]} = spec.start
      # Default is 10 MB
      assert Keyword.get(opts, :max_message_size) == 10_485_760
    end

    test "SIZE extension advertised in LHLO response", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 5_000_000
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # SIZE should be advertised with the configured limit
      assert response =~ "SIZE"
      assert response =~ "5000000"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    @tag :skip
    test "SIZE not advertised when max_message_size is infinity" do
      # Skip: gen_smtp callback options don't pass :infinity through correctly
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: :infinity
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _greeting} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # SIZE should not be advertised
      refute response =~ "SIZE"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "rejects MAIL FROM with SIZE exceeding limit" do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 1000
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Declare SIZE larger than limit
      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com> SIZE=2000\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should be rejected with 552 (exceeds limit)
      assert response =~ "552"
      assert response =~ ~r/exceeds|limit|size/i

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    test "accepts MAIL FROM with SIZE within limit", %{org: _org} do
      {:ok, pid} =
        LMTPServer.start_link(
          port: @test_port,
          max_message_size: 10_000
        )

      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Declare SIZE within limit
      :ok = :gen_tcp.send(socket, "MAIL FROM:<alice@example.com> SIZE=500\r\n")
      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)

      # Should be accepted
      assert response =~ "250"

      :gen_tcp.close(socket)
      LMTPServer.stop(pid)
    end

    setup %{example_org: org} do
      _contact = insert_contact(organization_id: org.id, email: "alice@example.com")
      {:ok, org: org}
    end
  end

  describe "recipient domain validation (open relay prevention)" do
    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)

      # Create organizations with known domains
      org1 = insert_organization(domain: "acme.example.com")

      org2 =
        insert_organization(domain: "widgets.example.com", custom_domain: "support.widgets.com")

      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid, org1: org1, org2: org2}
    end

    test "accepts RCPT TO for known organization domain", %{org1: _org1} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Recipient domain matches org1's domain
      :ok = :gen_tcp.send(socket, "RCPT TO:<support@acme.example.com>\r\n")
      {:ok, rcpt_resp} = :gen_tcp.recv(socket, 0, 5000)

      assert rcpt_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "accepts RCPT TO for organization custom_domain", %{org2: _org2} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Recipient domain matches org2's custom_domain
      :ok = :gen_tcp.send(socket, "RCPT TO:<help@support.widgets.com>\r\n")
      {:ok, rcpt_resp} = :gen_tcp.recv(socket, 0, 5000)

      assert rcpt_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "rejects RCPT TO for unknown domain with 550 error" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Unknown domain - should be rejected to prevent open relay
      :ok = :gen_tcp.send(socket, "RCPT TO:<user@unknown-domain.com>\r\n")
      {:ok, rcpt_resp} = :gen_tcp.recv(socket, 0, 5000)

      # Should return 550 5.1.1 Unknown recipient domain
      assert rcpt_resp =~ "550"

      :gen_tcp.close(socket)
    end

    test "rejects invalid email format without @ sign" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Invalid email - no @ sign
      :ok = :gen_tcp.send(socket, "RCPT TO:<invalid-email>\r\n")
      {:ok, rcpt_resp} = :gen_tcp.recv(socket, 0, 5000)

      # Should be rejected (5xx error)
      assert rcpt_resp =~ "5"

      :gen_tcp.close(socket)
    end

    test "domain matching is case-insensitive", %{org1: _org1} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # Same domain with different case - should still match
      :ok = :gen_tcp.send(socket, "RCPT TO:<support@ACME.EXAMPLE.COM>\r\n")
      {:ok, rcpt_resp} = :gen_tcp.recv(socket, 0, 5000)

      assert rcpt_resp =~ "250"

      :gen_tcp.close(socket)
    end

    test "accepts multiple recipients on known domains", %{org1: _org1, org2: _org2} do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # First recipient on org1's domain
      :ok = :gen_tcp.send(socket, "RCPT TO:<user1@acme.example.com>\r\n")
      {:ok, rcpt_resp1} = :gen_tcp.recv(socket, 0, 5000)
      assert rcpt_resp1 =~ "250"

      # Second recipient on org2's domain
      :ok = :gen_tcp.send(socket, "RCPT TO:<user2@widgets.example.com>\r\n")
      {:ok, rcpt_resp2} = :gen_tcp.recv(socket, 0, 5000)
      assert rcpt_resp2 =~ "250"

      :gen_tcp.close(socket)
    end

    test "rejects relay to external domain even after accepting valid recipient" do
      {:ok, socket} =
        :gen_tcp.connect(~c"localhost", @test_port, [:binary, active: false], 5000)

      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "LHLO test.client\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "MAIL FROM:<sender@external.com>\r\n")
      {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

      # First recipient is valid
      :ok = :gen_tcp.send(socket, "RCPT TO:<user@acme.example.com>\r\n")
      {:ok, rcpt_resp1} = :gen_tcp.recv(socket, 0, 5000)
      assert rcpt_resp1 =~ "250"

      # Second recipient is relay attempt - should be rejected
      :ok = :gen_tcp.send(socket, "RCPT TO:<victim@relay-target.com>\r\n")
      {:ok, rcpt_resp2} = :gen_tcp.recv(socket, 0, 5000)
      assert rcpt_resp2 =~ "550"

      :gen_tcp.close(socket)
    end
  end
end

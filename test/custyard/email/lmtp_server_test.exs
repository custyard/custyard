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
    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      # Create test org/contact for email processing
      org = insert_organization(domain: "example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@example.com")

      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid, org: org}
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

    test "creates conversation from processed email", %{org: org} do
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

      # Verify conversation was created
      conversations = Custyard.Conversations.list_for_organization(org.id)
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
    setup do
      {:ok, pid} = LMTPServer.start_link(port: @test_port)
      org = insert_organization(domain: "example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@example.com")

      on_exit(fn -> LMTPServer.stop(pid) end)
      {:ok, server: pid, org: org}
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

    test "can send multiple messages via separate connections", %{org: org} do
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

      # Should have created conversations for both messages
      conversations = Custyard.Conversations.list_for_organization(org.id)
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
end

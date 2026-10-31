defmodule Custyard.RuntimeLoggingPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Custyard.Email.{LMTPServer, Parser}
  alias Custyard.Log

  setup do
    previous = Logger.get_module_level([LMTPServer, Parser])
    Enum.each([LMTPServer, Parser], &Logger.put_module_level(&1, :debug))

    on_exit(fn ->
      Enum.each([LMTPServer, Parser], &Logger.delete_module_level/1)
      Enum.each(previous, fn {module, level} -> Logger.put_module_level(module, level) end)
    end)

    :ok
  end

  test "malformed MIME header diagnostics exclude the original content" do
    private = "PERSONAL_HEADER_CANARY*"

    raw =
      "From: private@example.test\r\nSubject: =?UTF-8?B?#{private}?=\r\n\r\nprivate message body"

    log = capture_log(fn -> assert {:ok, _parsed} = Parser.parse(raw) end)

    assert log =~ "email_header_decode_failed"
    refute log =~ private
    refute log =~ "private@example.test"
    refute log =~ "private message body"
  end

  test "LMTP diagnostic events omit envelopes and reset transaction correlation" do
    first_id = Log.new_id()
    metadata_before = Logger.metadata()

    state = %{
      from: "sender-private@example.test",
      to: ["recipient-private@example.test"],
      organization: nil,
      max_message_size: 1,
      log_operation_id: first_id
    }

    {result, first_log} =
      with_log([metadata: [:operation_id, :size_bytes]], fn ->
        LMTPServer.handle_DATA(state.from, state.to, "PRIVATE-BODY-CANARY", state)
      end)

    assert {:multiple, [{:error, _reply}], next} = result
    assert next.from == nil
    assert next.to == []
    assert is_binary(next.log_operation_id)
    refute next.log_operation_id == first_id
    assert first_log =~ "lmtp_message_received"
    assert first_log =~ "lmtp_message_size_rejected"
    assert first_log =~ first_id

    next = %{next | from: state.from, to: state.to}

    second_log =
      capture_log([metadata: [:operation_id]], fn ->
        assert {:multiple, _, _} =
                 LMTPServer.handle_DATA(next.from, next.to, "SECOND-PRIVATE-CANARY", next)
      end)

    assert second_log =~ next.log_operation_id
    refute second_log =~ first_id

    for value <- [state.from, hd(state.to), "PRIVATE-BODY-CANARY", "SECOND-PRIVATE-CANARY"] do
      refute first_log =~ value
      refute second_log =~ value
    end

    assert Logger.metadata() == metadata_before
  end

  test "LMTP error telemetry preserves retry categories when the reason is an exception" do
    private = "PROVIDER_EXCEPTION_CANARY-person@example.test\r\nFORGED EVENT"
    reason = %RuntimeError{message: private}

    for category <- [:temporary, :permanent] do
      metadata = LMTPServer.error_telemetry_metadata(category, reason)

      assert metadata == %{result: :error, error_type: category, reason: :exception}
      refute inspect(metadata) =~ private
      refute inspect(metadata) =~ "person@example.test"
      refute inspect(metadata) =~ "FORGED EVENT"
    end
  end

  test "LMTP telemetry exporters receive counts rather than peer or termination contents" do
    handler_id = "runtime-logging-privacy-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach_many(
      handler_id,
      [[:custyard, :lmtp, :connection, :open], [:custyard, :lmtp, :connection, :close]],
      fn event, _measurements, metadata, _ -> send(caller, {:privacy_event, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _banner, state} =
             LMTPServer.init(~c"mail.private.test", 0, {{203, 0, 113, 42}, 12_345},
               allowed_ips: :any
             )

    assert_received {:privacy_event, [:custyard, :lmtp, :connection, :open], opened}
    assert Map.keys(opened) == [:tls_enabled]

    private_reason = {:private, "TERMINATION_CONTENT_CANARY"}

    capture_log(fn ->
      assert {:ok, ^private_reason, _} = LMTPServer.terminate(private_reason, state)
    end)

    assert_received {:privacy_event, [:custyard, :lmtp, :connection, :close], closed}
    assert closed == %{messages_processed: 0}
  end
end

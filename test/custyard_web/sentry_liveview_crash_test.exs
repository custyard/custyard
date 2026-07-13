defmodule CustyardWeb.SentryLiveViewCrashTest do
  @moduledoc """
  End-to-end proof for the LiveView/process-crash scrubbing path.

  A crashed `ConversationLive` never passes through `Sentry.PlugContext`;
  `Sentry.LoggerHandler` reports it by `inspect/1`-ing the crashed socket state
  into the event message and `:extra.crash_reason`. Because the raw access
  token lives in socket assigns, it surfaces there as a bare `access_token:
  "..."` value — the exact shape this test drives with a real crash (not a
  fabricated string) and then confirms `Custyard.Sentry.before_send/1` removes.
  """
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Phoenix.LiveViewTest

  alias Custyard.{Intake, RateLimit}
  alias Sentry.Interfaces.Message

  @generous [limit: 1000, window_ms: 60_000]

  setup do
    RateLimit.reset()
    original = Application.get_env(:custyard, :rate_limit_buckets)

    Application.put_env(:custyard, :rate_limit_buckets,
      intake_get: @generous,
      intake_post: @generous,
      conversation_mount: @generous,
      conversation_reply: @generous,
      email_capture: @generous,
      claim_submit: @generous,
      claim_confirm: @generous,
      claim_email_send: @generous
    )

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original)
      RateLimit.reset()
    end)

    :ok
  end

  # Sentry.Event enforces :event_id and :timestamp.
  defp event(fields) do
    struct!(
      %Sentry.Event{event_id: "crash-test", timestamp: "2026-07-13T00:00:00Z"},
      fields
    )
  end

  # Crash a real ConversationLive and return the inspected raw :logger crash
  # report — i.e. what Sentry.LoggerHandler would turn into an event.
  defp capture_crash_report(token) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :logger.add_handler(:crash_capture, :logger_std_h, %{
      level: :all,
      config: %{type: :standard_error},
      filters: [
        capture:
          {fn
             %{level: :error} = ev, _ ->
               Agent.update(agent, &[ev | &1])
               :stop

             _ev, _ ->
               :ignore
           end, :ok}
      ]
    })

    Process.flag(:trap_exit, true)
    {:ok, view, _html} = live(build_conn(), "/c/#{token}")

    # Force a crash: an event with no matching handle_event/3 clause. The LV
    # process dies and render_hook re-raises the exit into this process.
    try do
      render_hook(view, "definitely_unhandled_event", %{})
    catch
      _kind, _reason -> :ok
    end

    # Let the crash report propagate to the logger handler.
    report =
      wait_for(agent, 50)

    :logger.remove_handler(:crash_capture)
    Agent.stop(agent)

    report
  end

  defp wait_for(_agent, 0), do: nil

  defp wait_for(agent, attempts) do
    case Agent.get(agent, & &1) do
      [ev | _] ->
        inspect(ev.msg, limit: :infinity, printable_limit: :infinity)

      [] ->
        Process.sleep(20)
        wait_for(agent, attempts - 1)
    end
  end

  test "a real ConversationLive crash report is scrubbed of the raw access token" do
    source = insert_intake_source(mode: :active)
    {:ok, %{access_token: token}} = Intake.create_intake_conversation(source.key, "Hello crash")

    report = capture_crash_report(token)

    # Sanity: the raw report really does leak the token (else the test proves
    # nothing). If this fails, the crash shape changed — re-probe.
    assert is_binary(report), "no crash report captured"
    assert report =~ token, "expected the raw crash report to contain the token"
    assert report =~ "access_token:"

    # Feed the real report into the two fields Sentry.LoggerHandler populates
    # from it, then run the actual before_send callback.
    scrubbed =
      event(
        message: %Message{formatted: report, message: report},
        extra: %{crash_reason: report}
      )
      |> Custyard.Sentry.before_send()

    refute scrubbed.message.formatted =~ token,
           "access token leaked into the scrubbed crash message"

    refute scrubbed.extra.crash_reason =~ token,
           "access token leaked into scrubbed extra.crash_reason"

    assert scrubbed.message.formatted =~ ~s|access_token: "[REDACTED]"|
  end
end

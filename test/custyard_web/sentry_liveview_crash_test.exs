defmodule CustyardWeb.SentryLiveViewCrashTest do
  @moduledoc """
  End-to-end proof for the LiveView/process-crash scrubbing path.

  A crashed `ConversationLive` never passes through `Sentry.PlugContext`.
  The global logger boundary must remove its socket state before any handler
  receives the report. The Sentry send boundary independently minimizes the
  resulting event. Both boundaries are exercised with a real crash.
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

  # Capture after the primary logger filter, at the same boundary used by
  # console and Sentry handlers. A handler must never receive raw socket state.
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

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      {:ok, view, _html} = live(build_conn(), "/c/#{token}")

      # An event with no matching handle_event/3 clause crashes the actual LV.
      try do
        render_hook(view, "definitely_unhandled_event", %{})
      catch
        _kind, _reason -> :ok
      end

      wait_for(agent, 50)
    after
      :logger.remove_handler(:crash_capture)
      Agent.stop(agent)
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp wait_for(_agent, 0), do: nil

  defp wait_for(agent, attempts) do
    case Agent.get(agent, & &1) do
      [ev | _] ->
        inspect(ev, limit: :infinity, printable_limit: :infinity)

      [] ->
        Process.sleep(20)
        wait_for(agent, attempts - 1)
    end
  end

  test "a real ConversationLive crash is safe before handlers and before Sentry export" do
    source = insert_intake_source(mode: :active)
    private = "UNLABELLED-CUSTOMER-CONTENT-CANARY"
    {:ok, %{access_token: token}} = Intake.create_intake_conversation(source.key, private)

    report = capture_crash_report(token)

    assert is_binary(report), "no crash report captured"
    refute report =~ token, "access token reached a logger handler"
    refute report =~ private, "customer content reached a logger handler"
    refute report =~ "access_token:"

    scrubbed =
      event(
        message: %Message{formatted: report, message: report},
        extra: %{crash_reason: report, operator_id: 7}
      )
      |> Custyard.Sentry.before_send()

    assert scrubbed.message.formatted == "application_error"
    assert scrubbed.extra == %{operator_id: 7}
    refute inspect(scrubbed, limit: :infinity) =~ token
    refute inspect(scrubbed, limit: :infinity) =~ private
  end
end

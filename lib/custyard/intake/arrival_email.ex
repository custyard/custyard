defmodule Custyard.Intake.ArrivalEmail do
  @moduledoc """
  Composes and delivers the operator "a prospect arrived" notification.

  Public-intake submissions previously produced only a PubSub broadcast,
  which reaches nothing unless an operator already has the attention queue
  open in a browser. This is the out-of-band arrival signal.

  Direction matters for the content rules. `Intake.ClaimEmail` goes *to* a
  prospect, so it may carry no prospect-supplied content — it must be
  useless as a spam relay. This one goes *to the operator* at the
  configured `:operator_email`, an address the operator chose, so it does
  carry the submission excerpt: without it the alert can't be triaged.
  Prospect text is HTML-escaped in the body and run through the shared
  `Custyard.Email.Headers` discipline in the subject, where a bare newline
  would be header injection.

  Gated by `:email_enabled` (`EMAIL_NOTIFICATIONS_ENABLED`), the same flag
  as neglect alerts, and bounded by the `:intake_arrival_email` rate bucket
  keyed by intake source. Delivery runs through the supervised task pool
  when `:deliver_replies_async?` is set (sync in test).

  Every failure mode is non-fatal by construction: this is called
  post-commit, so the conversation, prospect, and message rows are already
  durable and the queue entry exists regardless. A dropped alert costs
  latency on triage, never data.
  """

  import Swoosh.Email

  require Logger

  alias Custyard.Email.Headers
  alias Custyard.{Conversation, IntakeSource, RateLimit, Settings}

  # Enough to triage without turning the alert into a full mail client.
  @excerpt_max_length 500

  @doc """
  Notify the operator that a public-intake submission arrived.

  `conversation` is the committed conversation, `source` the intake source
  it came through, and `body` the (already normalized and truncated)
  submission text.

  Returns `{:ok, metadata}` / `{:error, reason}` when delivering
  synchronously, `{:ok, :queued}` when the task supervisor takes the job,
  `{:error, :queue_failed}` when it refuses (down or at `max_children`),
  `{:error, :rate_limited}` when the per-source bound is exhausted, and
  `{:error, :disabled}` when email notifications are switched off. Callers
  are expected to ignore the result — see the moduledoc.
  """
  def send_arrival(%Conversation{} = conversation, %IntakeSource{} = source, body) do
    if email_enabled?() do
      case RateLimit.check_rate(:intake_arrival_email, source.key) do
        {:deny, _retry_after_ms} ->
          Logger.warning(
            "Intake arrival notification rate-limited for source #{source.key}; " <>
              "conversation #{conversation.id} is in the queue but unannounced"
          )

          {:error, :rate_limited}

        {:allow, _count} ->
          conversation
          |> compose(source, body)
          |> deliver(conversation)
      end
    else
      {:error, :disabled}
    end
  end

  @doc """
  Compose the arrival notification without delivering (testable seam).
  """
  def compose(%Conversation{} = conversation, %IntakeSource{} = source, body) do
    excerpt = excerpt(body)
    conversation_url = operator_conversation_url(conversation)

    new()
    |> to(operator_email())
    |> from({from_display_name(), from_address()})
    |> subject(arrival_subject(conversation, source))
    |> text_body(arrival_text(conversation, source, excerpt, conversation_url))
    |> html_body(arrival_html(conversation, source, excerpt, conversation_url))
  end

  defp deliver(email, conversation) do
    if Application.get_env(:custyard, :deliver_replies_async?, true) do
      case Task.Supervisor.start_child(Custyard.TaskSupervisor, fn ->
             do_deliver(email, conversation)
           end) do
        {:ok, _pid} -> {:ok, :queued}
        {:error, _reason} -> {:error, :queue_failed}
      end
    else
      do_deliver(email, conversation)
    end
  end

  defp do_deliver(email, conversation) do
    case Custyard.Mailer.deliver(email) do
      {:ok, _metadata} = result ->
        Logger.info("Intake arrival notification sent for conversation #{conversation.id}")
        result

      {:error, reason} = error ->
        # The conversation is committed and already in the queue; a failed
        # alert costs triage latency, not data.
        Logger.error(
          "Failed to send intake arrival notification for conversation " <>
            "#{conversation.id}: #{inspect(reason)}"
        )

        error
    end
  end

  # The subject carries prospect text, so it must survive header
  # sanitization before it is handed to Swoosh.
  defp arrival_subject(conversation, source) do
    label = conversation.subject || "(no subject)"

    Headers.sanitize_header_text("[Intake] #{source.name}: #{label}")
  end

  defp excerpt(body) when is_binary(body) do
    if String.length(body) > @excerpt_max_length do
      String.slice(body, 0, @excerpt_max_length) <> "…"
    else
      body
    end
  end

  defp excerpt(_body), do: ""

  defp operator_conversation_url(conversation) do
    CustyardWeb.Endpoint.url() <> "/operator/conversation/#{conversation.id}"
  end

  defp email_enabled? do
    Application.get_env(:custyard, :email_enabled, false)
  end

  defp operator_email do
    Application.get_env(:custyard, :operator_email, "operator@example.com")
  end

  defp from_display_name do
    (Settings.get_branding().name || "Custyard")
    |> Headers.sanitize_header_text()
    |> Headers.quote_display_name()
  end

  defp from_address do
    Application.get_env(:custyard, :email_from_address, "noreply@custyard.local")
  end

  defp arrival_text(conversation, source, excerpt, conversation_url) do
    """
    A new prospect arrived through #{source.name} (#{source.key}).

    Subject: #{conversation.subject || "(no subject)"}

    #{excerpt}

    Open the conversation:

    #{conversation_url}
    """
  end

  defp arrival_html(conversation, source, excerpt, conversation_url) do
    safe_subject = html_escape(conversation.subject || "(no subject)")
    safe_source = html_escape("#{source.name} (#{source.key})")
    safe_excerpt = excerpt |> html_escape() |> String.replace("\n", "<br>")

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 24px;">
        <p style="color: #6b7280; font-size: 14px; margin-top: 0;">
          New prospect via <strong>#{safe_source}</strong>
        </p>
        <p style="color: #111827; font-size: 18px; font-weight: 600; margin: 8px 0 16px;">
          #{safe_subject}
        </p>
        <div style="background: white; border: 1px solid #e5e7eb; border-radius: 6px; padding: 16px; color: #374151; font-size: 14px;">
          #{safe_excerpt}
        </div>
        <div style="text-align: center; margin: 24px 0 8px;">
          <a href="#{conversation_url}" style="display: inline-block; background: #4f46e5; color: white; padding: 12px 32px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 16px;">
            Open the conversation
          </a>
        </div>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all; text-align: center;">#{conversation_url}</p>
      </div>
    </body>
    </html>
    """
  end

  defp html_escape(value) when is_binary(value) do
    case Phoenix.HTML.html_escape(value) do
      {:safe, iodata} -> IO.iodata_to_binary(iodata)
      iodata when is_list(iodata) or is_binary(iodata) -> IO.iodata_to_binary(iodata)
    end
  end

  defp html_escape(nil), do: ""
end

defmodule Custyard.Intake.ReceiptEmail do
  @moduledoc """
  Composes and delivers the prospect's submission receipt — the email that
  carries their resume URL.

  Without it, the `/c/:token` link exists only in a cookie. A prospect who
  submits from a phone and follows up from a laptop, or who clears cookies,
  loses the thread permanently: the token *is* the credential and only its
  hash is stored, so nothing can reconstruct the link. Operator replies
  then sit `:withheld` forever with no way to reach the person who asked.

  Follows the `Custyard.Intake.ClaimEmail` content rule strictly, because
  this mail goes *to* a prospect at an address that is attacker-chosen at
  submit time: the body carries ONLY the operator-configured source name,
  the platform resume URL, and fixed copy — never the submitted message,
  never its derived subject. This mail must be useless as a spam relay.
  The caller owns URL construction, matching ClaimEmail and LoginEmail.

  Sent whenever an email was captured, independent of `notify_on_reply`.
  That flag is consent for *operator replies* (spec-public-intake.md,
  "Prospect notification on operator reply"); the receipt is transactional
  — it is the delivery mechanism for the prospect's own access link, the
  same footing as the claim confirmation. Gating it on the checkbox would
  withhold the link from exactly the people most likely to lose it.

  Bounded by the `:intake_receipt_email` bucket keyed by the (already
  downcased) captured address. Delivery runs through the supervised task
  pool when `:deliver_replies_async?` is set (sync in test). A failure
  changes nothing about the submission: the conversation, prospect, and
  message rows are committed before this is called.
  """

  import Swoosh.Email

  require Logger

  alias Custyard.Email.Headers
  alias Custyard.{IntakeSource, RateLimit, Settings}

  @doc """
  Send the submission receipt to a captured prospect address.

  Requires `:conversation_url` in `opts` — the caller owns URL
  construction. Returns `{:ok, metadata}` / `{:error, reason}` when
  delivering synchronously, `{:ok, :queued}` when the task supervisor
  takes the job, `{:error, :queue_failed}` when it refuses,
  `{:error, :rate_limited}` when the per-address bound is exhausted, and
  `{:error, :disabled}` when email notifications are switched off.
  """
  def send_receipt(email, %IntakeSource{} = source, opts) when is_binary(email) do
    conversation_url = Keyword.fetch!(opts, :conversation_url)

    if email_enabled?() do
      case RateLimit.check_rate(:intake_receipt_email, email) do
        {:deny, _retry_after_ms} ->
          {:error, :rate_limited}

        {:allow, _count} ->
          email
          |> compose(source, conversation_url)
          |> deliver()
      end
    else
      {:error, :disabled}
    end
  end

  @doc """
  Compose the receipt without delivering (testable seam).
  """
  def compose(email, %IntakeSource{} = source, conversation_url) when is_binary(email) do
    new()
    |> to(email)
    |> from({from_display_name(), from_address()})
    |> subject(Headers.sanitize_header_text("We received your message"))
    |> text_body(receipt_text(source, conversation_url))
    |> html_body(receipt_html(source, conversation_url))
  end

  defp deliver(email_struct) do
    if Application.get_env(:custyard, :deliver_replies_async?, true) do
      case Task.Supervisor.start_child(Custyard.TaskSupervisor, fn ->
             do_deliver(email_struct)
           end) do
        {:ok, _pid} -> {:ok, :queued}
        {:error, _reason} -> {:error, :queue_failed}
      end
    else
      do_deliver(email_struct)
    end
  end

  # The recipient address is deliberately absent from both log lines: it is
  # prospect PII, and the conversation is durable without it.
  defp do_deliver(email_struct) do
    case Custyard.Mailer.deliver(email_struct) do
      {:ok, _metadata} = result ->
        Logger.info("Intake receipt sent")
        result

      {:error, reason} = error ->
        Logger.error("Failed to send intake receipt: #{inspect(reason)}")
        error
    end
  end

  defp email_enabled? do
    Application.get_env(:custyard, :email_enabled, false)
  end

  defp from_display_name do
    (Settings.get_branding().name || "Custyard")
    |> Headers.sanitize_header_text()
    |> Headers.quote_display_name()
  end

  defp from_address do
    Application.get_env(:custyard, :email_from_address, "noreply@custyard.local")
  end

  # Operator-configured source name only — no submitted content.
  defp receipt_text(source, conversation_url) do
    """
    Thanks for contacting us through #{source.name}. Your message is with
    our team and we will reply on this thread.

    Return to your conversation any time with this link:

    #{conversation_url}

    Keep it somewhere safe — anyone with the link can read and reply to
    this conversation, and we cannot send you a replacement.
    """
  end

  defp receipt_html(source, conversation_url) do
    safe_source = html_escape(source.name)

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 24px;">
        <p style="color: #374151; font-size: 16px; margin-top: 0;">
          Thanks for contacting us through <strong>#{safe_source}</strong>. Your
          message is with our team and we will reply on this thread.
        </p>
        <div style="text-align: center; margin: 24px 0;">
          <a href="#{conversation_url}" style="display: inline-block; background: #4f46e5; color: white; padding: 12px 32px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 16px;">
            Return to your conversation
          </a>
        </div>
        <p style="color: #6b7280; font-size: 14px;">Or copy and paste this link into your browser:</p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{conversation_url}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">
          Keep this link somewhere safe — anyone with it can read and reply to
          this conversation, and we cannot send you a replacement.
        </p>
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

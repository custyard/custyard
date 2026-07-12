defmodule Custyard.Intake.ClaimEmail do
  @moduledoc """
  Composes and delivers the slug-claim confirmation email.

  Follows the `Custyard.Auth.LoginEmail` pattern: direct Swoosh composition
  delivered via `Custyard.Mailer`. From is the platform address
  (`:email_from_address` config) with the instance branding name as the
  display name — never an operator's personal address — run through the
  shared `Custyard.Email.Headers` discipline.

  The body contains ONLY the claimed slug and platform links (the `/c`
  confirmation URL and the `/r` resume URL) — NEVER prospect-supplied
  content: this mail must be useless as a spam relay.

  Sends are bounded by the `:claim_email_send` rate bucket keyed by the
  claim's (already-downcased) anchor email. Delivery runs through the
  supervised task pool when `:deliver_replies_async?` is set (sync in
  test). A mailer failure changes nothing about the claim — the row and
  its token hash are already committed, and the resend path mints a fresh
  token.
  """

  import Swoosh.Email

  require Logger

  alias Custyard.Email.Headers
  alias Custyard.{RateLimit, Settings, Slug}

  @doc """
  Send the confirmation email for a freshly claimed (or token-rotated)
  slug.

  Requires `:confirm_url` and `:resume_url` in `opts` — the caller owns
  URL construction (LoginEmail precedent). Returns `{:ok, metadata}` /
  `{:error, reason}` when delivering synchronously, `{:ok, :queued}` when
  the async flag hands delivery to the task supervisor,
  `{:error, :queue_failed}` when the task supervisor refuses the job (down
  or at `max_children`), or `{:error, :rate_limited}` when the per-email
  daily send bound is exhausted (nothing is sent or queued).
  """
  def send_confirmation(%Slug{} = slug, opts) do
    confirm_url = Keyword.fetch!(opts, :confirm_url)
    resume_url = Keyword.fetch!(opts, :resume_url)

    case RateLimit.check_rate(:claim_email_send, slug.email) do
      {:deny, _retry_after_ms} ->
        {:error, :rate_limited}

      {:allow, _count} ->
        slug
        |> compose(confirm_url, resume_url)
        |> deliver(slug)
    end
  end

  @doc """
  Compose the confirmation email without delivering (testable seam).
  """
  def compose(%Slug{} = slug, confirm_url, resume_url) do
    new()
    |> to(slug.email)
    |> from({from_display_name(), from_address()})
    |> subject("Confirm your claim: #{slug.slug}")
    |> text_body(confirmation_text(slug.slug, confirm_url, resume_url))
    |> html_body(confirmation_html(slug.slug, confirm_url, resume_url))
  end

  defp deliver(email, slug) do
    if Application.get_env(:custyard, :deliver_replies_async?, true) do
      case Task.Supervisor.start_child(Custyard.TaskSupervisor, fn -> do_deliver(email, slug) end) do
        {:ok, _pid} -> {:ok, :queued}
        {:error, _reason} -> {:error, :queue_failed}
      end
    else
      do_deliver(email, slug)
    end
  end

  defp do_deliver(email, slug) do
    case Custyard.Mailer.deliver(email) do
      {:ok, _metadata} = result ->
        Logger.info("Slug claim confirmation sent for #{slug.slug}")
        result

      {:error, reason} = error ->
        # The claim row is untouched: it stays intact and re-sendable.
        Logger.error(
          "Failed to send slug claim confirmation for #{slug.slug}: #{inspect(reason)}"
        )

        error
    end
  end

  # Instance branding name (operator-configured, "Custyard" fallback) under
  # the shared header discipline — sanitized and quoted like every other
  # display name this codebase emits.
  defp from_display_name do
    (Settings.get_branding().name || "Custyard")
    |> Headers.sanitize_header_text()
    |> Headers.quote_display_name()
  end

  defp from_address do
    Application.get_env(:custyard, :email_from_address, "noreply@custyard.local")
  end

  defp confirmation_text(slug, confirm_url, resume_url) do
    """
    You claimed the name: #{slug}

    Confirm your claim by opening this link and pressing Confirm:

    #{confirm_url}

    You can return to your conversation any time with your resume link:

    #{resume_url}

    If you didn't claim this name, you can safely ignore this email.
    """
  end

  defp confirmation_html(slug, confirm_url, resume_url) do
    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 24px;">
        <p style="color: #374151; font-size: 16px; margin-top: 0;">
          You claimed the name: <strong>#{slug}</strong>
        </p>
        <div style="text-align: center; margin: 24px 0;">
          <a href="#{confirm_url}" style="display: inline-block; background: #4f46e5; color: white; padding: 12px 32px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 16px;">
            Confirm your claim
          </a>
        </div>
        <p style="color: #6b7280; font-size: 14px;">Or copy and paste this link into your browser:</p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{confirm_url}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #6b7280; font-size: 14px;">
          Return to your conversation any time with your resume link:
        </p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{resume_url}</p>
        <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">
          If you didn't claim this name, you can safely ignore this email.
        </p>
      </div>
    </body>
    </html>
    """
  end
end

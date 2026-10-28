defmodule Custyard.Intake.ClaimEmail do
  @moduledoc """
  Composes and delivers the slug-claim confirmation email.

  Follows the `Custyard.Auth.LoginEmail` pattern: direct Swoosh composition
  delivered via `Custyard.Mailer`. Nondefault tenants use their selected support
  sender and project credentials; the default instance keeps its configured platform
  address. The tenant or instance display name is run through the
  shared `Custyard.Email.Headers` discipline.

  The body contains ONLY staff-configured branding, the claimed slug and tenant links (the `/c`
  confirmation URL and the `/c` thread URL) — NEVER prospect-supplied
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

  alias Custyard.{RateLimit, Slug}
  alias Custyard.Intake.EmailBranding

  @doc """
  Send the confirmation email for a freshly claimed (or token-rotated)
  slug.

  Requires `:confirm_url` and `:thread_url` in `opts` — the caller owns
  URL construction (LoginEmail precedent). Returns `{:ok, metadata}` /
  `{:error, reason}` when delivering synchronously, `{:ok, :queued}` when
  the async flag hands delivery to the task supervisor,
  `{:error, :queue_failed}` when the task supervisor refuses the job (down
  or at `max_children`), or `{:error, :rate_limited}` when the per-email
  daily send bound is exhausted (nothing is sent or queued).
  """
  def send_confirmation(%Slug{} = slug, opts) do
    confirm_url = Keyword.fetch!(opts, :confirm_url)
    thread_url = Keyword.fetch!(opts, :thread_url)

    with {:ok, delivery} <-
           EmailBranding.delivery_settings(EmailBranding.tenant_id_for_claim(slug)) do
      case RateLimit.check_rate(:claim_email_send, {slug.tenant_id, slug.email}) do
        {:deny, _retry_after_ms} ->
          {:error, :rate_limited}

        {:allow, _count} ->
          slug
          |> compose(confirm_url, thread_url, delivery)
          |> deliver(slug, delivery.config)
      end
    end
  end

  @doc """
  Compose the confirmation email without delivering (testable seam).
  """
  def compose(%Slug{} = slug, confirm_url, thread_url, delivery \\ nil) do
    branding = EmailBranding.for_claim(slug)

    new()
    |> to(slug.email)
    |> EmailBranding.put_sender(branding, delivery || EmailBranding.tenant_id_for_claim(slug))
    |> subject("Confirm your claim: #{slug.slug}")
    |> text_body(
      EmailBranding.text_header(branding) <>
        confirmation_text(slug.slug, confirm_url, thread_url)
    )
    |> html_body(confirmation_html(slug.slug, confirm_url, thread_url, branding))
  end

  defp deliver(email, slug, config) do
    if Application.get_env(:custyard, :deliver_replies_async?, true) do
      case Task.Supervisor.start_child(Custyard.TaskSupervisor, fn ->
             do_deliver(email, slug, config)
           end) do
        {:ok, _pid} -> {:ok, :queued}
        {:error, _reason} -> {:error, :queue_failed}
      end
    else
      do_deliver(email, slug, config)
    end
  end

  defp do_deliver(email, slug, config) do
    case Custyard.Mailer.deliver(email, config) do
      {:ok, _metadata} = result ->
        Logger.info("Slug claim confirmation sent for #{slug.slug}")
        result

      {:error, _reason} = error ->
        # The claim row is untouched: it stays intact and re-sendable.
        Logger.error("Failed to send slug claim confirmation for #{slug.slug}")

        error
    end
  end

  defp confirmation_text(slug, confirm_url, thread_url) do
    """
    You claimed the name: #{slug}

    Confirm your claim by opening this link and pressing Confirm:

    #{confirm_url}

    You can return to your thread any time with your thread link:

    #{thread_url}

    If you didn't claim this name, you can safely ignore this email.
    """
  end

  defp confirmation_html(slug, confirm_url, thread_url, branding) do
    slug = EmailBranding.escape(slug)
    confirm_url = EmailBranding.escape(confirm_url)
    thread_url = EmailBranding.escape(thread_url)

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 24px;">
        #{EmailBranding.html_header(branding)}
        <p style="color: #374151; font-size: 16px; margin-top: 0;">
          You claimed the name: <strong>#{slug}</strong>
        </p>
        <div style="text-align: center; margin: 24px 0;">
          <a href="#{confirm_url}" style="display: inline-block; background: #{branding.color}; color: white; padding: 12px 32px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 16px;">
            Confirm your claim
          </a>
        </div>
        <p style="color: #6b7280; font-size: 14px;">Or copy and paste this link into your browser:</p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{confirm_url}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #6b7280; font-size: 14px;">
          Return to your thread any time with your thread link:
        </p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{thread_url}</p>
        <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">
          If you didn't claim this name, you can safely ignore this email.
        </p>
      </div>
    </body>
    </html>
    """
  end
end

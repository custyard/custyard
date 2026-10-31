defmodule CustyardWeb.IntakeController do
  @moduledoc """
  Public intake pages — the anonymous, hammerable dead views.

  GET renders an active (form-first) or passive (informational) page per the
  operator-configured intake source; unknown and disabled keys render the
  standard 404. POST validates the message body *before* touching the
  context, creates the conversation through
  `Custyard.Intake.create_intake_conversation/3`, sets the signed conversation
  cookie, and redirects to the conversation URL. Malformed or oversized input
  re-renders the form with a structured error — never a 500.

  Deliberately a controller, not a LiveView: these surfaces take anonymous
  traffic and must stay cheap per request. All domain logic lives in
  `Custyard.Intake`; this module only validates shape and renders.
  """

  use CustyardWeb, :controller

  require Custyard.Log, as: Log

  import Phoenix.Component, only: [to_form: 2]

  alias Custyard.Email.Normalizer
  alias Custyard.Intake.ReceiptEmail
  alias Custyard.{Intake, IntakeSource, Settings, Tenants}
  alias CustyardWeb.Plugs.ConversationCookie

  plug :put_layout, html: {CustyardWeb.Layouts, :intake}
  plug CustyardWeb.Plugs.PublicRateLimit, [bucket: :intake_get] when action == :show
  plug CustyardWeb.Plugs.PublicRateLimit, [bucket: :intake_post] when action == :create
  plug :assign_branding
  plug :load_source

  def show(conn, _params) do
    # Passive GETs (and active ones) create nothing — pure render.
    render_intake(conn, empty_form())
  end

  def create(conn, params) do
    submission = extract_submission(params)

    case validate_body(submission.body) do
      {:ok, body} ->
        create_conversation(conn, body, submission)

      {:error, message} ->
        render_submission_error(conn, submission, message)
    end
  end

  ## Submission handling -------------------------------------------------------

  defp create_conversation(conn, body, submission) do
    source = conn.assigns.intake_source

    case Intake.create_intake_conversation(source.key, body) do
      {:ok, %{conversation: conversation, access_token: token}} ->
        capture_result = maybe_capture_email(conversation, submission.email, submission.notify)
        receipt_result = maybe_send_receipt(capture_result, conversation, source, token)

        emit_submission(source, capture_result, receipt_result)

        conn
        |> ConversationCookie.put_conversation_cookie(token)
        |> maybe_flash_rejected_email(capture_result)
        |> redirect(to: ~p"/c/#{token}")

      # The source was disabled or deleted between load_source and the
      # context's own lookup — same treatment as an unknown key, but a
      # strictly more alarming signal: this one ate a real submission.
      {:error, :unknown_source} ->
        render_not_found(conn, :disabled_mid_submission)

      # Server-side loss: the Multi inserting conversation + prospect + message
      # did not commit. The prospect sees a generic failure and leaves. Strictly
      # more likely than the disabled-source race above, and the failure mode
      # that would take the submission counter to zero while looking like a
      # quiet week — so it reports rather than dying silently.
      {:error, %Ecto.Changeset{} = changeset} ->
        emit_submission_rejected(source, changeset)
        render_submission_error(conn, submission, "could not be submitted")
    end
  end

  # The optional email is captured after creation. A capture failure
  # (invalid address, concurrent capture) must never fail the submission
  # itself — the conversation and conversation redirect stand either way.
  defp maybe_capture_email(conversation, email, notify) do
    if String.trim(email) != "" do
      Intake.capture_email(conversation, email, notify: notify)
    else
      {:error, :no_email}
    end
  end

  # The submission stands either way, but a rejected address was the
  # prospect's only way to hear back (and to get the resume URL); say so on
  # the conversation page, where the email prompt lets them fix it.
  defp maybe_flash_rejected_email(conn, {:error, %Ecto.Changeset{}}) do
    put_flash(
      conn,
      :error,
      "Your message was sent, but that email address doesn't look valid. " <>
        "Add your email below to receive replies."
    )
  end

  defp maybe_flash_rejected_email(conn, _capture_result), do: conn

  # Only a successful capture earns a receipt, and it is addressed to the
  # stored (normalized, downcased) value rather than the raw submission.
  # This is the only moment the plaintext access token exists — it is
  # hashed at rest — so the resume URL cannot be reconstructed later.
  # Result ignored: everything above is committed, and ReceiptEmail owns
  # its own gating, rate limiting, and failure logging.
  defp maybe_send_receipt({:ok, _captured}, conversation, source, token) do
    case Intake.get_prospect(conversation) do
      %{email: email} when is_binary(email) ->
        case ReceiptEmail.send_receipt(email, source,
               conversation_url:
                 Tenants.url(Tenants.get_tenant!(source.tenant_id)) <> ~p"/c/#{token}"
             ) do
          {:ok, _} -> :sent
          {:error, _} -> :skipped
        end

      _no_email ->
        :skipped
    end
  end

  defp maybe_send_receipt(_capture_failed, _conversation, _source, _token), do: :skipped

  # Shape-validate the message body BEFORE any context call: non-binary and
  # oversized params get a structured 4xx with the form re-rendered, never
  # a 500. Size is bounded in bytes (not graphemes) so the check is O(1).
  defp validate_body(body) when is_binary(body) do
    cond do
      String.trim(body) == "" ->
        {:error, "can't be blank"}

      byte_size(body) > Normalizer.max_body_length() ->
        {:error, "is too long (maximum is #{Normalizer.max_body_length()} bytes)"}

      true ->
        {:ok, body}
    end
  end

  defp validate_body(_body), do: {:error, "is invalid"}

  # Normalizes untrusted params into a safe shape: only binaries survive.
  defp extract_submission(params) do
    submission =
      case params["submission"] do
        %{} = map -> map
        _other -> %{}
      end

    %{
      body: submission["body"],
      email: if(is_binary(submission["email"]), do: submission["email"], else: ""),
      notify: submission["notify"] == "true"
    }
  end

  ## Rendering -----------------------------------------------------------------

  defp render_intake(conn, form) do
    source = conn.assigns.intake_source
    template = if source.mode == :passive, do: :passive, else: :active

    conn
    |> assign_conversation_banner()
    |> assign_active_path(source)
    |> render(template, source: source, form: form)
  end

  defp render_submission_error(conn, submission, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_intake(form_with_error(submission, message))
  end

  defp empty_form do
    to_form(%{"body" => "", "email" => "", "notify" => "false"}, as: :submission)
  end

  defp form_with_error(submission, message) do
    to_form(
      %{
        "body" => if(is_binary(submission.body), do: submission.body, else: ""),
        "email" => submission.email,
        "notify" => to_string(submission.notify)
      },
      as: :submission,
      errors: [body: {message, []}]
    )
  end

  # "Resume your conversation" banner: shown when the signed conversation cookie
  # verifies against a live (non-revoked, non-purged) prospect. Only a link —
  # conversation content never renders on the intake page, so the check is
  # the lightweight access_token_valid?/1, never the preloaded thread.
  defp assign_conversation_banner(conn) do
    conn = fetch_cookies(conn, signed: [ConversationCookie.cookie_name()])
    token = conn.cookies[ConversationCookie.cookie_name()]

    conversation_path =
      if is_binary(token) and Intake.access_token_valid?(token) do
        ~p"/c/#{token}"
      end

    assign(conn, :conversation_path, conversation_path)
  end

  # Passive pages link to the active flow; the pairing policy (first enabled
  # active source, ordered by key) lives in the Intake context — this module
  # only builds the path. Omitted when none exists.
  defp assign_active_path(conn, %IntakeSource{mode: :passive}) do
    active = Intake.first_enabled_active_source(conn.assigns.intake_source.tenant_id)
    assign(conn, :active_path, active && ~p"/i/#{active.key}")
  end

  defp assign_active_path(conn, _source), do: assign(conn, :active_path, nil)

  ## Plugs ---------------------------------------------------------------------

  defp assign_branding(conn, _opts) do
    assign(conn, :branding, Settings.get_branding())
  end

  # Unknown or disabled keys render the standard 404 — table lookup only,
  # request input is never converted to an atom (Intake.get_enabled_source/1).
  defp load_source(conn, _opts) do
    case Intake.get_enabled_source(conn.path_params["source_key"]) do
      nil ->
        render_not_found(conn, :unknown_key)

      %IntakeSource{} = source ->
        host_tenant = conn.assigns[:host_tenant]

        if is_nil(host_tenant) or source.tenant_id == host_tenant.id do
          conn
          |> assign(:intake_source, source)
          |> assign(
            :branding,
            if(source.tenant_id == 1,
              do: Settings.get_branding(),
              else: Tenants.branding(Tenants.get_tenant!(source.tenant_id))
            )
          )
        else
          render_not_found(conn, :unknown_key)
        end
    end
  end

  defp render_not_found(conn, reason) do
    Log.warning(:intake_source_unavailable, reason: reason)

    :telemetry.execute(
      [:custyard, :intake, :unknown_source],
      %{count: 1},
      %{reason: reason}
    )

    # Capture only the same bounded diagnostic fields used in runtime logs.
    Sentry.capture_message("intake: no enabled source for key",
      level: if(reason == :disabled_mid_submission, do: :error, else: :warning),
      fingerprint: ["intake-unknown-source", to_string(reason)],
      extra: %{reason: reason}
    )

    conn
    |> put_status(:not_found)
    |> put_view(CustyardWeb.ErrorHTML)
    |> render("404.html")
    |> halt()
  end

  ## Instrumentation -----------------------------------------------------------

  # The one event that answers "did submissions stop, or is it just quiet?".
  # Logged as well as emitted: metrics/0 has no reporter attached, so `fly logs`
  # is the only consumer that exists today.
  defp emit_submission(source, capture_result, receipt_result) do
    email_captured = match?({:ok, _}, capture_result)

    Log.info(:intake_submission_accepted,
      source_id: source.id,
      tenant_id: source.tenant_id,
      mode: source.mode,
      email_captured: email_captured,
      receipt: receipt_result
    )

    :telemetry.execute(
      [:custyard, :intake, :submission],
      %{count: 1},
      %{mode: source.mode, email_captured: email_captured, receipt: receipt_result}
    )
  end

  # A submission the server refused. Only the changeset's error *shape* is
  # reported — never the values, which are untrusted prospect input and the
  # message body itself.
  defp emit_submission_rejected(source, changeset) do
    Log.error(
      :intake_submission_rejected,
      [source_id: source.id, tenant_id: source.tenant_id] ++ Log.failure(changeset)
    )

    :telemetry.execute(
      [:custyard, :intake, :submission_rejected],
      %{count: 1},
      %{mode: source.mode}
    )

    Sentry.capture_message("intake: submission rejected by the database",
      level: :error,
      fingerprint: ["intake-submission-rejected"],
      extra:
        Map.new([source_id: source.id, tenant_id: source.tenant_id] ++ Log.failure(changeset))
    )
  end
end

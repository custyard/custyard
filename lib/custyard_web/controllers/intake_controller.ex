defmodule CustyardWeb.IntakeController do
  @moduledoc """
  Public intake pages — the anonymous, hammerable dead views.

  GET renders an active (form-first) or passive (informational) page per the
  operator-configured intake source; unknown and disabled keys render the
  standard 404. POST validates the message body *before* touching the
  context, creates the conversation through
  `Custyard.Intake.create_intake_conversation/3`, sets the signed resume
  cookie, and redirects to the resume URL. Malformed or oversized input
  re-renders the form with a structured error — never a 500.

  Deliberately a controller, not a LiveView: these surfaces take anonymous
  traffic and must stay cheap per request. All domain logic lives in
  `Custyard.Intake`; this module only validates shape and renders.
  """

  use CustyardWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias Custyard.Email.Normalizer
  alias Custyard.{Intake, IntakeSource, Settings}
  alias CustyardWeb.Plugs.ResumeCookie

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
      {:ok, %{conversation: conversation, resume_token: token}} ->
        maybe_capture_email(conversation, submission.email, submission.notify)

        conn
        |> ResumeCookie.put_resume_cookie(token)
        |> redirect(to: ~p"/r/#{token}")

      # The source was disabled or deleted between load_source and the
      # context's own lookup — same treatment as an unknown key.
      {:error, :unknown_source} ->
        render_not_found(conn)

      {:error, %Ecto.Changeset{}} ->
        render_submission_error(conn, submission, "could not be submitted")
    end
  end

  # The optional passive-form email is captured after creation. A capture
  # failure (invalid address, concurrent capture) must never fail the
  # submission itself — the conversation and resume redirect stand either way.
  defp maybe_capture_email(conversation, email, notify) do
    if String.trim(email) != "" do
      _result = Intake.capture_email(conversation, email, notify: notify)
    end

    :ok
  end

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
    |> assign_resume_banner()
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

  # "Resume your conversation" banner: shown when the signed resume cookie
  # verifies against a live (non-revoked, non-purged) prospect. Only a link —
  # conversation content never renders on the intake page, so the check is
  # the lightweight resume_token_valid?/1, never the preloaded thread.
  defp assign_resume_banner(conn) do
    conn = fetch_cookies(conn, signed: [ResumeCookie.cookie_name()])
    token = conn.cookies[ResumeCookie.cookie_name()]

    resume_path =
      if is_binary(token) and Intake.resume_token_valid?(token) do
        ~p"/r/#{token}"
      end

    assign(conn, :resume_path, resume_path)
  end

  # Passive pages link to the active flow; the pairing policy (first enabled
  # active source, ordered by key) lives in the Intake context — this module
  # only builds the path. Omitted when none exists.
  defp assign_active_path(conn, %IntakeSource{mode: :passive}) do
    active = Intake.first_enabled_active_source()
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
      nil -> render_not_found(conn)
      %IntakeSource{} = source -> assign(conn, :intake_source, source)
    end
  end

  defp render_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(CustyardWeb.ErrorHTML)
    |> render("404.html")
    |> halt()
  end
end

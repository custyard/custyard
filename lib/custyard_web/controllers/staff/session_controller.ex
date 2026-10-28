defmodule CustyardWeb.Staff.SessionController do
  use CustyardWeb, :controller

  alias Custyard.{StaffAccount, RateLimit, Repo}
  alias Custyard.Auth.{Account, LoginEmail}
  alias CustyardWeb.Live.StaffAuth
  alias CustyardWeb.Plugs.PublicRateLimit

  require Logger

  # Base64url character class for validating token format
  @token_pattern ~r/^[A-Za-z0-9_-]+$/

  plug :rate_limit_login,
       [bucket: :account_login_ip] when action == :create

  # Shows the flash set by whatever sent the staff here: the
  # :require_staff plug, the LiveView auth hooks, or logout.
  def new(conn, _params) do
    render(conn, :new,
      error: Phoenix.Flash.get(conn.assigns.flash, :error),
      email: nil,
      info: Phoenix.Flash.get(conn.assigns.flash, :info),
      layout: false
    )
  end

  def create(conn, %{"email" => email}) when is_binary(email) and email != "" do
    # The same normalization the account was stored with, for both the
    # per-email rate-limit key and the lookup.
    email = StaffAccount.normalize_email(email)

    case RateLimit.check_rate(:account_login_email, {conn.assigns.host_tenant.id, email}) do
      {:deny, retry_after_ms} ->
        Logger.info("account_login_skipped", reason: :email_rate_limited)

        retry_after_s = max(div(retry_after_ms + 999, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_status(429)
        |> put_view(CustyardWeb.ErrorHTML)
        |> render("429.html")

      {:allow, _count} ->
        deliver_login_link(conn, email)
    end
  end

  def create(conn, _params) do
    Logger.info("account_login_skipped", reason: :missing_email)

    render(conn, :new,
      error: "Email is required.",
      email: nil,
      info: nil,
      layout: false
    )
  end

  defp rate_limit_login(conn, opts) do
    # Log before the IP limiter can halt, without recording submitted params.
    # Plug.RequestId metadata follows this synchronous request through delivery.
    Logger.info("account_login_requested")

    conn = PublicRateLimit.call(conn, PublicRateLimit.init(opts))

    if conn.halted do
      Logger.info("account_login_skipped", reason: :ip_rate_limited)
    end

    conn
  end

  defp deliver_login_link(conn, email) do
    case Repo.get_by(StaffAccount, tenant_id: conn.assigns.host_tenant.id, email: email) do
      nil ->
        # Don't reveal whether the email exists — always show success page
        Logger.info("account_login_skipped", reason: :unknown_account)

      %StaffAccount{} = staff ->
        if StaffAccount.orphaned?(staff) do
          # An admin or agent whose organization was deleted gets no link;
          # the response below stays identical so this reveals nothing.
          Logger.info("account_login_skipped",
            reason: :no_organization,
            staff_id: staff.id
          )
        else
          send_login_link(staff, conn.assigns.host_tenant)
        end
    end

    # Keep the response identical whether the account exists or not.
    conn
    |> put_session(:login_sent_email, email)
    |> redirect(to: ~p"/app/login/sent")
  end

  defp send_login_link(staff, tenant) do
    updated_staff = ensure_login_token(staff)

    login_url =
      Custyard.Tenants.url(tenant) <>
        ~p"/app/login/verify/#{updated_staff.login_token}"

    LoginEmail.deliver_login_link(updated_staff, login_url)
  end

  # Re-send the outstanding link while it is still valid instead of minting a
  # new token on every request. The per-email bucket admits a handful of
  # requests an hour from anyone, so rotating on each of them let a stranger
  # who knew a staff's address invalidate the link that staff was
  # about to click.
  #
  # The fresh token is written only while no valid one is stored, and the
  # link is built from whatever the row then holds: two concurrent requests
  # (a double-submitted form) converge on one token instead of the second
  # write invalidating the email the first one already sent.
  defp ensure_login_token(staff), do: Account.ensure_login_token(staff)

  def sent(conn, _params) do
    email = get_session(conn, :login_sent_email)

    conn
    |> delete_session(:login_sent_email)
    |> render(:sent, email: email || "", layout: false)
  end

  # GET peeks: the link in the email renders a page with a "Log in" button
  # and changes nothing, so a mail scanner or link prefetcher that follows
  # the URL neither consumes the single-use token (leaving the staff with
  # "expired") nor walks away with a staff session. Only the explicit
  # POST below consumes the token. Same pattern as ClaimConfirmationController.
  def verify(conn, %{"token" => token}) do
    case lookup_login_token(conn, token) do
      {:ok, _staff} ->
        render(conn, :verify, token: token, layout: false)

      {:error, :expired} ->
        render_expired_token(conn)

      {:error, :invalid} ->
        render_invalid_token(conn)

      {:error, :no_organization} ->
        render_no_organization(conn)
    end
  end

  def consume(conn, %{"token" => token}) do
    with {:ok, staff} <- lookup_login_token(conn, token),
         :ok <- clear_login_token(staff, token) do
      conn
      |> configure_session(renew: true)
      |> put_session(:staff_id, staff.id)
      # The id alone could later name a different account (SQLite reuses
      # the highest id after a delete); see StaffAuth.session_staff/2.
      |> put_session(:staff_claim, StaffAccount.session_claim(staff))
      |> put_flash(:info, "Welcome back")
      |> redirect(to: ~p"/app")
    else
      {:error, :expired} -> render_expired_token(conn)
      {:error, :invalid} -> render_invalid_token(conn)
      {:error, :no_organization} -> render_no_organization(conn)
    end
  end

  # Clear the token so it can't be reused. Conditional on the token still
  # being stored, so of two concurrent POSTs with one link only the first
  # gets a session.
  defp clear_login_token(staff, token),
    do: Account.consume_login_token(staff, token)

  # A link minted before the staff's organization was deleted still
  # verifies, but never yields a session. Only the token holder sees why.
  defp lookup_login_token(conn, token) do
    with true <- String.match?(token, @token_pattern),
         %StaffAccount{} = staff <-
           Repo.get_by(StaffAccount,
             tenant_id: conn.assigns.host_tenant.id,
             login_token: token
           ) do
      cond do
        not StaffAccount.verify_login_token(staff, token) -> {:error, :expired}
        not Custyard.Tenants.active?(staff.tenant_id) -> {:error, :no_organization}
        true -> {:ok, staff}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp render_expired_token(conn) do
    render(conn, :new,
      error: "This login link has expired. Please request a new one.",
      email: nil,
      info: nil,
      layout: false
    )
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:staff_id)
    |> delete_session(:staff_claim)
    |> put_flash(:info, "Logged out")
    |> redirect(to: ~p"/app/login")
  end

  defp render_no_organization(conn) do
    render(conn, :new,
      error: StaffAuth.no_organization_message(),
      email: nil,
      info: nil,
      layout: false
    )
  end

  defp render_invalid_token(conn) do
    render(conn, :new,
      error: "Invalid or expired login link. Please request a new one.",
      email: nil,
      info: nil,
      layout: false
    )
  end
end

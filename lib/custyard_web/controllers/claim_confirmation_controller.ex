defmodule CustyardWeb.ClaimConfirmationController do
  @moduledoc """
  Scanner-safe slug-claim confirmation — the `/c` dead views.

  GET `/claim/:token` PEEKS: it renders the claimed slug and a Confirm button
  with ZERO state change, so mail-scanner prefetch can never consume the
  single-use token. POST `/claim/:token/confirm` consumes it via
  `Custyard.Slugs.confirm/1` (race-safe conditional update).

  Invalid, expired, already-used, and purged tokens ALL render one
  identical generic page (the PR-6 uniform-unavailable pattern) — token
  handling exposes no validity oracle. The success page deliberately does
  not mint or reveal the conversation URL: the email the prospect already holds
  is the only carrier of that credential.
  """

  use CustyardWeb, :controller

  alias Custyard.{Settings, Slugs}

  plug :put_layout, html: {CustyardWeb.Layouts, :intake}
  # Shape check BEFORE the rate limit: a path segment that cannot possibly
  # have been minted by Custyard.Auth.Token renders the same uniform
  # unavailable page without spending a :claim_confirm token, so scanner
  # garbage never starves a real confirmation. Every well-formed token
  # still passes through the rate limit BEFORE any lookup — accounting can
  # reveal token SHAPE (public knowledge from the code), never whether a
  # token EXISTS.
  plug :reject_malformed_token
  plug CustyardWeb.Plugs.PublicRateLimit, bucket: :claim_confirm
  plug :assign_branding

  def show(conn, %{"token" => token}) do
    case Slugs.peek(token) do
      {:ok, slug} ->
        conn
        |> assign(:page_title, "Confirm your claim")
        |> render(:show, slug: slug, token: token)

      {:error, :invalid} ->
        render_unavailable(conn)
    end
  end

  def confirm(conn, %{"token" => token}) do
    case Slugs.confirm(token) do
      {:ok, slug} ->
        conn
        |> assign(:page_title, "Claim confirmed")
        |> render(:confirmed, slug: slug)

      {:error, :invalid} ->
        render_unavailable(conn)
    end
  end

  # One identical rendering for every failure class — same template, same
  # status, same assigns — mirroring the conversation surface's unavailable page.
  defp render_unavailable(conn) do
    conn
    |> assign(:page_title, "Confirmation unavailable")
    |> render(:unavailable)
  end

  # Custyard.Auth.Token mints 32 random bytes url-base64-encoded without
  # padding — always exactly 43 chars of [A-Za-z0-9_-]. Anything else can
  # never match a stored hash, no matter what the database holds, so
  # rejecting it here is a pure-shape decision with zero existence signal.
  @token_shape ~r/\A[A-Za-z0-9_-]{43}\z/

  defp reject_malformed_token(conn, _opts) do
    if Regex.match?(@token_shape, conn.path_params["token"] || "") do
      conn
    else
      # Byte-identical to the post-rate-limit failure page: same branding,
      # same template, same 200 — only the rate-limit accounting differs.
      conn
      |> assign_branding([])
      |> render_unavailable()
      |> halt()
    end
  end

  defp assign_branding(conn, _opts) do
    assign(conn, :branding, Settings.get_branding())
  end
end

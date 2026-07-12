defmodule CustyardWeb.ClaimConfirmationController do
  @moduledoc """
  Scanner-safe slug-claim confirmation — the `/c` dead views.

  GET `/c/:token` PEEKS: it renders the claimed slug and a Confirm button
  with ZERO state change, so mail-scanner prefetch can never consume the
  single-use token. POST `/c/:token/confirm` consumes it via
  `Custyard.Slugs.confirm/1` (race-safe conditional update).

  Invalid, expired, already-used, and purged tokens ALL render one
  identical generic page (the PR-6 uniform-unavailable pattern) — token
  handling exposes no validity oracle. The success page deliberately does
  not mint or reveal the resume URL: the email the prospect already holds
  is the only carrier of that credential.
  """

  use CustyardWeb, :controller

  alias Custyard.{Settings, Slugs}

  plug :put_layout, html: {CustyardWeb.Layouts, :intake}
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
  # status, same assigns — mirroring the resume surface's unavailable page.
  defp render_unavailable(conn) do
    conn
    |> assign(:page_title, "Confirmation unavailable")
    |> render(:unavailable)
  end

  defp assign_branding(conn, _opts) do
    assign(conn, :branding, Settings.get_branding())
  end
end

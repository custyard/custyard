defmodule CustyardWeb.Plugs.ConversationCookie do
  @moduledoc """
  Refreshes the signed conversation cookie on valid `/c/:token` HTTP GETs.

  The conversation URL is the primary credential; the `"_custyard_conversation"` cookie is
  a convenience that powers the "Resume your conversation" banner on intake
  pages. Each valid conversation visit re-issues the cookie so a returning prospect
  keeps the banner alive for another year.

  Two guards keep the refresh inside the surface's discipline:

    * The token is verified with the lightweight
      `Custyard.Intake.access_token_valid?/1` — an indexed prospect lookup
      with the same predicate `ProspectAuth` authenticates with; the plug
      needs validity only, never the preloaded thread.
    * The refresh honors the `:conversation_mount` budget via a non-counting
      `Custyard.RateLimit.peek/2`. `ProspectAuth`'s mount check owns and
      counts that budget (so the HTTP mount that follows this plug is not
      double-billed), but once a client is over the limit no lookup runs
      and no cookie is set — the refresh is neither an unthrottled probe
      nor, during a deny window, a Set-Cookie validity oracle.

  Invalid, revoked, and unknown tokens leave the connection untouched — no
  cookie is set and none is cleared (clearing would turn this plug into a
  validity oracle for cookie-holding clients).

  `put_conversation_cookie/2` is the single place the cookie attributes live;
  `CustyardWeb.IntakeController` uses it on the post-submit redirect.
  """

  @behaviour Plug

  import Plug.Conn

  alias Custyard.{Intake, RateLimit}
  alias CustyardWeb.ClientIP

  @cookie_name "_custyard_conversation"
  # One year, per the public-intake design decisions: the Phoenix session
  # cookie's 24-hour max-age disqualifies it for months-later returns.
  @max_age 31_536_000

  @doc "The conversation cookie name."
  def cookie_name, do: @cookie_name

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    with token when is_binary(token) <- conn.path_params["token"],
         {:allow, _count} <-
           RateLimit.peek(:conversation_mount, ClientIP.from_conn(conn) || "unknown"),
         true <- Intake.access_token_valid?(token) do
      put_conversation_cookie(conn, token)
    else
      _denied_or_invalid -> conn
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  Sets the signed conversation cookie with the canonical attributes: signed value
  (tamper-evident, but not confidential — the token is base64-encoded and
  readable as-is, same as the `/c/:token` URL it mirrors), one-year max-age,
  HTTP-only, `SameSite=Lax`, and `Secure` in production.
  """
  def put_conversation_cookie(conn, token) when is_binary(token) do
    put_resp_cookie(conn, @cookie_name, token,
      sign: true,
      max_age: @max_age,
      http_only: true,
      secure: Application.get_env(:custyard, :env) == :prod,
      same_site: "Lax"
    )
  end
end

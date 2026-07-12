defmodule CustyardWeb.Plugs.NoReferrer do
  @moduledoc """
  Sends `Referrer-Policy: no-referrer` on public intake surfaces.

  The conversation URL and the slug-claim confirmation URL are bearer credentials
  carried in the path: they must never leak to third parties through the
  `Referer` header when a prospect follows an outbound link.

  Mounted after `:browser`, so this deliberately overrides the weaker
  `strict-origin-when-cross-origin` default from
  `put_secure_browser_headers/2`. Applied to the `/i`, `/c`, and `/c`
  scopes.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    put_resp_header(conn, "referrer-policy", "no-referrer")
  end
end

defmodule CustyardWeb.Plugs.CacheRawBody do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.private`.

  Used as the `:body_reader` for `Plug.Parsers` so that webhook signature
  verification can access the exact bytes sent by the provider.

  ## Usage in endpoint.ex

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {CustyardWeb.Plugs.CacheRawBody, :read_body, []},
        json_decoder: Phoenix.json_library()

  Then access via `conn.private[:raw_body]` in controllers.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.put_private(conn, :raw_body, body)
    {:ok, body, conn}
  end
end

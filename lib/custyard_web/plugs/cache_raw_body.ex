defmodule CustyardWeb.Plugs.CacheRawBody do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.private`.

  Used as the `:body_reader` for `Plug.Parsers` so that webhook signature
  verification can access the exact bytes sent by the provider.

  ## Memory Protection

  Enforces a max body size of 1MB (configurable via `:webhook_max_body_size`).
  This protects against memory exhaustion since the body is cached alongside
  parsed params.

  ## Usage in endpoint.ex

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {CustyardWeb.Plugs.CacheRawBody, :read_body, []},
        json_decoder: Phoenix.json_library()

  Then access via `conn.private[:raw_body]` in controllers.
  """

  # Default max body size: 1MB - reasonable for webhook payloads
  @default_max_body_size 1_000_000

  def read_body(conn, opts) do
    # Enforce max body size to prevent memory exhaustion
    max_length = Application.get_env(:custyard, :webhook_max_body_size, @default_max_body_size)
    opts = Keyword.put_new(opts, :length, max_length)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, _partial, conn} ->
        # Body exceeds limit - return error
        {:error, :body_too_large, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule CustyardWeb.Plugs.PublicRateLimit do
  @moduledoc """
  Per-client-IP rate limiting for anonymous public HTTP surfaces.

  Usage:

      plug CustyardWeb.Plugs.PublicRateLimit, bucket: :intake_post

  The bucket is validated against `config :custyard, :rate_limit_buckets`
  at `init/1` (boot time), and the limit and window resolve again at
  request time via `Custyard.RateLimit.bucket_config!/1` — an
  unconfigured bucket fails fast and loud rather than 500ing on first
  request. The key is the client IP under the
  `CustyardWeb.ClientIP` trust discipline; malformed request input never
  raises (garbage headers fall back to the peer address).

  Over-limit requests halt with the standard 429 error page and a
  `Retry-After` header (seconds, rounded up).

  Plug limits only cover HTTP round trips — LiveView websocket events
  must call `Custyard.RateLimit.check_rate/2` directly.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  alias Custyard.RateLimit
  alias CustyardWeb.ClientIP

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    RateLimit.bucket_config!(bucket)
    %{bucket: bucket}
  end

  @impl true
  def call(conn, %{bucket: bucket}) do
    key = ClientIP.from_conn(conn)

    case RateLimit.check_rate(bucket, key) do
      {:allow, _count} -> conn
      {:deny, retry_after_ms} -> deny(conn, bucket, retry_after_ms)
    end
  end

  # Renders the standard error page the same way PortalAuth renders its 404.
  #
  # Instrumented here rather than downstream because this halts: nothing in the
  # controller ever runs for a denied request, so a counter placed there would
  # report zero while the limiter turned every visitor away. Deliberately not
  # sent to Sentry — a public surface under a scanner would generate one event
  # per rejected request. The log line and the counter are what distinguish
  # "the limiter is rejecting everyone" from "nobody is submitting".
  defp deny(conn, bucket, retry_after_ms) do
    Logger.warning("public rate limit exceeded", bucket: bucket)

    :telemetry.execute(
      [:custyard, :public_rate_limit, :exceeded],
      %{count: 1},
      %{bucket: bucket}
    )

    retry_after_s = max(div(retry_after_ms + 999, 1000), 1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> put_status(429)
    |> Phoenix.Controller.put_view(CustyardWeb.ErrorHTML)
    |> Phoenix.Controller.render("429.html")
    |> halt()
  end
end

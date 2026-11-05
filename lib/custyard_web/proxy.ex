defmodule CustyardWeb.Proxy do
  @moduledoc """
  Provider-aware origin authentication and forwarded-scheme handling.

  The endpoint wrapper runs before Phoenix's socket dispatch as well as the
  HTTP plug stack. Bunny must overwrite `X-Custyard-Origin` at its CDN edge;
  the value is removed before socket connect info and error context are built.
  Only the exact health-probe route bypasses origin authentication.
  """

  import Plug.Conn

  @behaviour Plug
  @origin_header "x-custyard-origin"

  defmacro __using__(_opts) do
    quote do
      @before_compile CustyardWeb.Proxy
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        conn = CustyardWeb.Proxy.call(conn, [])
        if conn.halted, do: conn, else: super(conn, opts)
      end
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    provider = Keyword.get(opts, :provider, CustyardWeb.ClientIP.proxy_provider())
    conn = authenticate_origin(conn, provider, opts)

    if conn.halted do
      conn
    else
      conn
      |> rewrite_scheme(provider)
      |> require_https(opts)
    end
  end

  defp authenticate_origin(conn, :bunny, opts) do
    expected = Keyword.get(opts, :secret, Application.get_env(:custyard, :bunny_origin_secret))
    supplied = get_req_header(conn, @origin_header)

    allowed? =
      health_probe?(conn) or
        (is_binary(expected) and byte_size(expected) >= 32 and
           match?([_], supplied) and Plug.Crypto.secure_compare(hd(supplied), expected))

    conn = drop_headers(conn, [@origin_header, "fly-client-ip"])

    if allowed? do
      conn
    else
      conn |> send_resp(:forbidden, "Forbidden") |> halt()
    end
  end

  defp authenticate_origin(conn, _provider, _opts), do: drop_headers(conn, [@origin_header])

  defp drop_headers(conn, names) do
    %{conn | req_headers: Enum.reject(conn.req_headers, fn {name, _value} -> name in names end)}
  end

  defp rewrite_scheme(conn, provider) when provider in [:fly, :bunny] do
    rewrite_provider_scheme(conn, provider)
  end

  defp rewrite_scheme(conn, _provider), do: conn

  # Bunny sets X-Forwarded-Proto but does not set X-Forwarded-Port. A visitor's
  # port header must never change application URLs or origin checks.
  defp rewrite_provider_scheme(conn, :bunny) do
    conn = drop_headers(conn, ["x-forwarded-port"])

    case get_req_header(conn, "x-forwarded-proto") do
      ["https"] -> %{conn | scheme: :https, port: 443}
      ["http"] -> %{conn | scheme: :http, port: 80}
      [] -> conn
      _ -> conn |> send_resp(:bad_request, "Invalid proxy headers") |> halt()
    end
  end

  defp rewrite_provider_scheme(conn, :fly) do
    # Never trust X-Forwarded-Host: tenant/custom-domain routing uses Host.
    Plug.RewriteOn.call(conn, Plug.RewriteOn.init([:x_forwarded_port, :x_forwarded_proto]))
  end

  defp require_https(%{halted: true} = conn, _opts), do: conn

  defp require_https(conn, opts) do
    if Keyword.get(opts, :https_required, Application.get_env(:custyard, :https_required, false)) do
      ssl_opts =
        Plug.SSL.init(
          host: nil,
          log: false,
          exclude: [
            hosts: ["localhost", "127.0.0.1"],
            conn: {__MODULE__, :health_probe?, []}
          ]
        )

      Plug.SSL.call(conn, ssl_opts)
    else
      conn
    end
  end

  @doc false
  def health_probe?(conn) do
    conn.method in ["GET", "HEAD"] and conn.request_path == "/api/health" and
      conn.query_string == ""
  end
end

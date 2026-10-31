defmodule CustyardWeb.Plugs.RequestLog do
  @moduledoc "Safe request summaries without URLs, query strings, parameters or headers."
  @behaviour Plug

  require Custyard.Log, as: Log
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if CustyardWeb.Endpoint.request_log_level(conn) == false do
      conn
    else
      started = System.monotonic_time(:millisecond)
      fields = [method: conn.method, route: route_class(conn.request_path)]
      Log.info(:http_request_started, fields)

      register_before_send(conn, fn response ->
        Log.info(
          :http_request_completed,
          fields ++
            [
              http_status: response.status,
              duration_ms: max(System.monotonic_time(:millisecond) - started, 0)
            ]
        )

        response
      end)
    end
  end

  defp route_class("/"), do: :root
  defp route_class("/api/health"), do: :health
  defp route_class("/operator/login"), do: :operator_login
  defp route_class("/operator/login/sent"), do: :operator_login
  defp route_class("/operator" <> _), do: :operator
  defp route_class("/i/" <> _), do: :intake
  defp route_class("/p/" <> _), do: :portal
  defp route_class("/claim/" <> _), do: :claim
  defp route_class("/api/webhook/" <> _), do: :webhook
  defp route_class(_), do: :other
end

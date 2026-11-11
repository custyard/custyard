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
  defp route_class("/app/login"), do: :staff_login
  defp route_class("/app/login/sent"), do: :staff_login
  defp route_class("/app"), do: :staff
  defp route_class("/app/" <> _), do: :staff
  defp route_class("/admin/login"), do: :instance_admin_login
  defp route_class("/admin"), do: :instance_admin
  defp route_class("/admin/" <> _), do: :instance_admin
  defp route_class("/intake/" <> _), do: :intake
  defp route_class("/portal/" <> _), do: :portal
  defp route_class("/threads/" <> _), do: :thread
  defp route_class("/claims/" <> _), do: :claim
  defp route_class("/api/webhook/" <> _), do: :webhook
  defp route_class(_), do: :other
end

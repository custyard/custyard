defmodule CustyardWeb.HostScope do
  @moduledoc "Captures the transport's actual host during mount, before connect info is discarded."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_info: 2]

  def capture(socket) do
    host =
      case get_connect_info(socket, :uri) do
        %URI{host: host} when is_binary(host) -> Custyard.Tenants.normalize_host(host)
        _ -> nil
      end

    assign(socket, :verified_host, host)
  end
end

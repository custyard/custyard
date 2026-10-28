defmodule Custyard.EmailSetupTestProvider do
  @moduledoc false
  def list_domains, do: response(:domains, nil, [])
  def verify_inbound_domain(id), do: response(:mx, id, [])
  def get_project(id, opts), do: response(:project, id, opts)
  def get_route(id, opts), do: response(:route, id, opts)
  def get_webhook(id, opts), do: response(:webhook, id, opts)
  def ping_sending(token, opts), do: response(:ping, token, opts)

  defp response(kind, id, opts) do
    fixture = Application.fetch_env!(:custyard, :email_setup_test_provider)
    if pid = fixture[:pid], do: send(pid, {:provider_read, kind, id, opts})

    case Map.fetch!(fixture, kind) do
      callback when is_function(callback, 0) -> callback.()
      result -> result
    end
  end
end

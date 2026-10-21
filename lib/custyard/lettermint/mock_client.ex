defmodule Custyard.Lettermint.MockClient do
  @moduledoc """
  Mock Lettermint API client for development and testing.

  Returns predictable responses without making HTTP requests. Route maps
  follow the unwrapped shape documented in `Custyard.Lettermint.Client`.

  `list_domains/0` returns `Application.get_env(:custyard, :lettermint_mock_domains, [])`
  so a test can stage domains:

      Application.put_env(:custyard, :lettermint_mock_domains, [
        %{"id" => "d1", "domain" => "acme.example.com", "status" => "verified"}
      ])

  and remove them again in `on_exit`.
  """

  @behaviour Custyard.Lettermint.Client

  @impl true
  def create_route(_params) do
    {:ok, route("lm_route_#{:erlang.unique_integer([:positive])}")}
  end

  @impl true
  def get_route(lettermint_route_id) do
    {:ok, route(lettermint_route_id)}
  end

  @impl true
  def delete_route(_lettermint_route_id) do
    :ok
  end

  @impl true
  def list_domains do
    {:ok, Application.get_env(:custyard, :lettermint_mock_domains, [])}
  end

  defp route(id) do
    %{
      "id" => id,
      "slug" => "mock-#{id}",
      "inbound_route_domain" => "#{random_lower_alnum(10)}.lettermint.app",
      "inbound_address" => "#{random_hex(32)}@inbound.lettermint.co",
      "inbound_domain" => nil,
      "inbound_domain_verified_at" => nil
    }
  end

  @alphabet ~c"abcdefghijklmnopqrstuvwxyz0123456789"

  defp random_lower_alnum(length) do
    for _ <- 1..length, into: "", do: <<Enum.random(@alphabet)>>
  end

  defp random_hex(length) do
    length
    |> div(2)
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end

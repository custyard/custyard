defmodule Custyard.Acknowledgments.ConfigTest do
  defp ack_scope(tenant_id) do
    key = {__MODULE__, :scope, tenant_id}

    case Process.get(key) do
      nil ->
        scope = Custyard.Factory.staff_scope(tenant_id)
        Process.put(key, scope)
        scope

      scope ->
        scope
    end
  end

  use Custyard.DataCase
  import Custyard.Factory
  alias Custyard.Acknowledgments
  alias Custyard.Acknowledgments.{Config, Consumer, Integration}

  defp config(overrides) do
    Keyword.merge(
      [
        enabled: true,
        url: nil,
        source: nil,
        queue: "tenant.acknowledgments",
        prefetch: 1,
        retry_delays: [10_000],
        confirm_timeout: 5_000,
        reconnect_delay: 5_000
      ],
      overrides
    )
  end

  test "subscription credentials are encrypted and scoped to the tenant" do
    a = insert_tenant()
    b = insert_tenant()
    url = "amqp://custyard:broker-secret@broker.internal/tenant"

    assert {:ok, integration} =
             Acknowledgments.configure_integration(
               Custyard.Scope.for_staff(
                 insert_staff_account(tenant_id: a.id, role: "admin"),
                 a
               ),
               %{url: url, source: "ots.test", queue: "tenant-a", enabled: true}
             )

    refute integration.url_ciphertext == url
    assert Config.load(a.id)[:url] == url
    assert Config.load(b.id)[:url] == nil
    assert Acknowledgments.subscription_status(ack_scope(a.id)) == :stopped
    assert Acknowledgments.subscription_status(ack_scope(b.id)) == :disabled
    refute inspect(Acknowledgments.subscription_overview(ack_scope(a.id))) =~ "broker-secret"
    refute inspect(Repo.get!(Integration, integration.id)) =~ "broker-secret"
  end

  test "a demoted scope cannot configure or inspect a tenant subscription" do
    tenant = insert_tenant()
    scope = ack_scope(tenant.id)

    assert {:ok, _} =
             Acknowledgments.configure_integration(
               scope,
               %{
                 url: "amqp://guest:guest@localhost",
                 source: "test",
                 queue: "test",
                 enabled: false
               }
             )

    Repo.get!(Custyard.StaffAccount, scope.staff_id)
    |> Ecto.Changeset.change(role: "agent")
    |> Repo.update!()

    assert {:error, :unauthorized} =
             Acknowledgments.configure_integration(
               scope,
               %{
                 url: "amqp://guest:guest@localhost",
                 source: "other",
                 queue: "other",
                 enabled: false
               }
             )

    assert {:error, :unauthorized} = Acknowledgments.bind(scope, "test", "customer", 1)
    assert {:error, :unauthorized} = Acknowledgments.subscription_overview(scope)
    assert Acknowledgments.list_bindings(scope) == []
    assert Acknowledgments.get_binding(scope, "test", "customer") == nil
  end

  test "incomplete and malformed configuration is refused without exposing the URL" do
    assert Config.startup(config(enabled: false), :prod) == :disabled
    assert_raise ArgumentError, fn -> Config.startup(config([]), :prod) end

    for url <- [
          "amqp://u:secret@broker.internal:99999",
          "amqp://u:secret@broker.internal/vhost/extra",
          "amqp://",
          "http://u:secret@broker.internal"
        ] do
      error =
        assert_raise ArgumentError, fn ->
          Config.startup(config(url: url, source: "ots.test"), :prod)
        end

      refute error.message =~ "secret"
      refute error.message =~ "broker.internal"
    end
  end

  test "remote TLS requires certificate verification" do
    url = "amqps://u:secret@broker.example.com/ots?verify=verify_none"

    assert Config.validation_error(config(url: url, source: "ots.test")) =~
             "TLS certificate verification"

    for url <- [
          "amqps://u:p@localhost?verify=verify_none",
          "amqps://u:p@rabbit.internal?verify=verify_none",
          "amqps://u:p@broker.example.com?verify=verify_peer"
        ] do
      assert Config.startup(config(url: url, source: "ots.test"), :prod) == :enabled
    end
  end

  test "consumer status output redacts the URL" do
    state = %{config: config(url: "amqp://u:secret@broker.internal"), channel: nil}
    formatted = Consumer.format_status(%{state: state, message: :connect, reason: :normal})
    assert formatted.state.config[:url] == "[REDACTED]"
    refute inspect(formatted) =~ "secret"
  end
end

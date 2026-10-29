defmodule Custyard.Acknowledgments.SubscriptionsTest do
  use Custyard.DataCase, async: false
  import Custyard.Factory
  alias Custyard.Acknowledgments.{Consumer, Integration, Subscriptions}
  alias Custyard.Credentials

  defp integration(tenant, url) do
    {:ok, ciphertext} = Credentials.encrypt(url, "acknowledgments.#{tenant.id}.url")

    Repo.insert!(%Integration{
      tenant_id: tenant.id,
      source: "test",
      queue: "subscription-#{tenant.id}",
      enabled: true,
      url_ciphertext: ciphertext
    })
  end

  test "one invalid tenant cannot prevent the subscription supervisor from starting" do
    bad = insert_tenant()
    integration(bad, "not-a-broker-url")
    pid = start_supervised!(Subscriptions)
    assert Process.alive?(pid)
    assert :global.whereis_name({Consumer, bad.id}) == :undefined
    assert Custyard.Acknowledgments.subscription_status(staff_scope(bad.id)) == :invalid_config

    saved = Repo.get_by!(Integration, tenant_id: bad.id)

    {:ok, corrected} =
      Credentials.encrypt("amqp://guest:guest@127.0.0.1:1", "acknowledgments.#{bad.id}.url")

    Repo.update!(Ecto.Changeset.change(saved, url_ciphertext: corrected))
    assert {:ok, _} = Subscriptions.refresh(bad.id)
    assert is_pid(:global.whereis_name({Consumer, bad.id}))
    assert Process.alive?(pid)
  end

  test "exhausting one subscription's restarts leaves the shared supervisor alive" do
    good = insert_tenant()
    bad = insert_tenant()
    integration(good, "amqp://guest:guest@127.0.0.1:1")
    integration(bad, "amqp://guest:guest@127.0.0.1:1")
    parent = start_supervised!(Subscriptions)
    healthy = :global.whereis_name({Consumer, good.id})
    assert is_pid(healthy)
    bad_id = bad.id

    {_, wrapper, _, _} =
      Enum.find(Supervisor.which_children(parent), fn {id, _, _, _} ->
        id == {Consumer, bad_id}
      end)

    wrapper_ref = Process.monitor(wrapper)

    Enum.reduce(1..4, :global.whereis_name({Consumer, bad_id}), fn attempt, pid ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      if attempt < 4,
        do: await_replacement(bad_id, pid, System.monotonic_time(:millisecond) + 2_000)
    end)

    assert_receive {:DOWN, ^wrapper_ref, :process, ^wrapper, _}, 2_000

    assert Process.alive?(parent)
    assert Process.alive?(healthy)
    assert :global.whereis_name({Consumer, bad.id}) == :undefined
    assert Consumer.status(bad.id) == :stopped
    assert {:ok, _} = Subscriptions.refresh(bad.id)
    assert is_pid(:global.whereis_name({Consumer, bad.id}))
    assert Process.alive?(healthy)
  end

  defp await_replacement(tenant_id, old, deadline) do
    case :global.whereis_name({Consumer, tenant_id}) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        await_replacement(tenant_id, old, deadline)
    end
  end
end

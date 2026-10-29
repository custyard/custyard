defmodule Custyard.IntakeTenantLifecycleTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Intake, Message, Tenant, Thread}

  setup do
    source = insert_intake_source()

    {:ok, result} =
      Intake.create_intake_thread(source.key, "Initial request", tenant_id: source.tenant_id)

    %{
      source: source,
      thread: result.thread,
      prospect: result.prospect,
      token: result.access_token
    }
  end

  test "suspension blocks new intake and every mounted prospect write", c do
    Repo.get!(Tenant, c.source.tenant_id)
    |> Ecto.Changeset.change(status: "suspended")
    |> Repo.update!()

    assert is_nil(Intake.get_enabled_source(c.source.key, c.source.tenant_id))

    assert {:error, :unknown_source} =
             Intake.create_intake_thread(c.source.key, "Blocked new request",
               tenant_id: c.source.tenant_id
             )

    assert {:error, :no_prospect} =
             Intake.add_prospect_reply(c.thread, "Blocked reply",
               token_hash: c.prospect.access_token_hash
             )

    assert {:error, :no_prospect} =
             Intake.set_notification(c.thread, true, token_hash: c.prospect.access_token_hash)

    assert {:error, :no_prospect} =
             Intake.capture_email(c.thread, "blocked@example.com",
               token_hash: c.prospect.access_token_hash
             )

    assert Repo.aggregate(Thread, :count) == 1
    assert Repo.aggregate(Message, :count) == 1
    assert is_nil(Repo.reload!(c.prospect).email)
  end

  test "a forged tenant on a thread handle cannot mutate its prospect", c do
    forged = %{c.thread | tenant_id: insert_tenant().id}
    assert {:error, :no_prospect} = Intake.add_prospect_reply(forged, "Blocked")
    assert {:error, :no_prospect} = Intake.set_notification(forged, true)
    assert {:error, :no_prospect} = Intake.capture_email(forged, "blocked@example.com")
    refute Repo.reload!(c.prospect).notify_on_reply
    assert Repo.aggregate(Message, :count) == 1
  end
end

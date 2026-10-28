defmodule Custyard.SettingsAuthorizationTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{OperatorAccount, Repo, Scope, Settings, Tenants}

  setup do
    tenant = insert_tenant()
    staff = insert_operator_account(tenant_id: tenant.id, role: "admin")
    %{tenant: tenant, staff: staff, scope: Scope.for_staff(staff, tenant)}
  end

  test "all settings mutations reject a stale demoted administrator", c do
    c.staff |> OperatorAccount.role_changeset(%{role: "agent"}) |> Repo.update!()
    assert_denied(c.scope)
    assert Settings.get_intake_config(c.tenant.id).unlinked_tier_score == 10
  end

  test "all settings mutations reject a revoked session", c do
    c.staff
    |> Ecto.Changeset.change(session_claim: OperatorAccount.generate_session_claim())
    |> Repo.update!()

    assert_denied(c.scope)
  end

  test "all settings mutations reject suspended tenants", c do
    c.tenant |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
    assert_denied(c.scope)
  end

  test "staff authority cannot be redirected to another tenant", c do
    foreign = insert_tenant()
    assert_denied(%{c.scope | tenant_id: foreign.id})
    assert {:ok, _} = Settings.update_intake_config(c.scope, %{unlinked_tier_score: 77})
    assert Settings.get_intake_config(c.tenant.id).unlinked_tier_score == 77
    assert Settings.get_intake_config(foreign.id).unlinked_tier_score == 10
    assert Tenants.active?(c.tenant.id)
  end

  defp assert_denied(scope) do
    assert {:error, :unauthorized} = Settings.update_weights(scope, %{idle: 2.0})
    assert {:error, :unauthorized} = Settings.update_thresholds(scope, %{standard: {2, 4}})

    assert {:error, :unauthorized} =
             Settings.update_intake_config(scope, %{unlinked_tier_score: 77})

    assert {:error, :unauthorized} = Settings.update_sieve_header_mappings(scope, %{})
  end
end

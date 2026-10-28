defmodule Custyard.AcknowledgmentsTest do
  defp local_authority(tenant_id, channel),
    do: %Custyard.Acknowledgments.LocalAuthority{tenant_id: tenant_id, channel: channel}

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
  alias Custyard.Acknowledgments
  alias Custyard.Acknowledgments.Evidence

  def evidence(overrides \\ %{}) do
    text = "Example pilot statement; not production wording.\n"

    Map.merge(
      %{
        "schema_version" => 1,
        "source" => "ots.test",
        "submission_id" => "submission-1",
        "organization_id" => "org-1",
        "actor_id" => "colonel-1",
        "actor_role" => "colonel",
        "actor_type" => "internal_staff",
        "statement_key" => "example",
        "statement_version" => "v1",
        "statement_text" => text,
        "statement_hash" => Base.encode16(:crypto.hash(:sha256, text), case: :lower),
        "acknowledged_at" => "2026-09-30T12:00:00Z"
      },
      overrides
    )
  end

  defp tenant_id, do: Process.get(:ack_test_tenant_id)

  setup do
    tenant = Custyard.Factory.insert_tenant()
    Process.put(:ack_test_tenant_id, tenant.id)

    organization =
      %Custyard.Organization{}
      |> Custyard.Organization.changeset(%{tenant_id: tenant_id(), name: "Pilot"})
      |> Repo.insert!()

    {:ok, _} =
      Custyard.Factory.create_acknowledgment_binding(%{
        tenant_id: tenant_id(),
        source: "ots.test",
        source_organization_id: "org-1",
        organization_id: organization.id
      })

    %{organization: organization}
  end

  test "redelivery preserves exact evidence, receipt time and one record", %{organization: org} do
    payload = evidence()
    assert {:ok, first} = Acknowledgments.ingest(tenant_id(), payload)
    assert {:ok, repeated} = Acknowledgments.ingest(tenant_id(), payload)
    assert repeated == first
    assert first.statement_text == payload["statement_text"]
    assert first.acknowledged_at == payload["acknowledged_at"]
    assert [^first] = Acknowledgments.list_for_organization(ack_scope(org.tenant_id), org.id)
  end

  test "conflicting reuse never changes evidence" do
    assert {:ok, first} = Acknowledgments.ingest(tenant_id(), evidence())

    assert {:error, :conflicting_submission} =
             Acknowledgments.ingest(tenant_id(), evidence(%{"actor_id" => "another"}))

    assert Repo.get!(Custyard.Acknowledgments.Acknowledgment, first.id).actor_id == "colonel-1"
  end

  test "source attribution needs an explicit binding and can recover", %{organization: org} do
    payload = evidence(%{"source" => "ots.other"})
    assert {:error, :unmapped_organization} = Acknowledgments.ingest(tenant_id(), payload)

    assert {:ok, _} =
             Custyard.Factory.create_acknowledgment_binding(%{
               tenant_id: tenant_id(),
               source: "ots.other",
               source_organization_id: "org-1",
               organization_id: org.id
             })

    assert {:ok, _} = Acknowledgments.ingest(tenant_id(), payload)

    assert {:error, changeset} =
             Custyard.Factory.create_acknowledgment_binding(%{
               tenant_id: tenant_id(),
               source: "ots.other",
               source_organization_id: "org-1",
               organization_id: org.id
             })

    refute changeset.valid?
  end

  test "distinct actions survive and listing is bounded", %{organization: org} do
    for n <- 1..3,
        do:
          assert(
            {:ok, _} =
              Acknowledgments.ingest(tenant_id(), evidence(%{"submission_id" => "event-#{n}"}))
          )

    assert length(
             Acknowledgments.list_for_organization(ack_scope(org.tenant_id), org.id, limit: 2)
           ) == 2

    assert length(
             Acknowledgments.list_for_organization(ack_scope(org.tenant_id), org.id,
               limit: 2,
               offset: 2
             )
           ) == 1
  end

  test "mapping provisioning is idempotent and never reassigns attribution", %{organization: org} do
    assert {:ok, :created, binding} =
             Acknowledgments.bind(
               local_authority(tenant_id(), "console"),
               "ots.test",
               "org-new",
               org.id
             )

    assert {:ok, :existing, ^binding} =
             Acknowledgments.bind(
               local_authority(tenant_id(), "console"),
               "ots.test",
               "org-new",
               org.id
             )

    assert {:ok, :existing, ^binding} =
             Acknowledgments.bind(
               local_authority(tenant_id(), "console"),
               "ots.test",
               "org-new",
               Integer.to_string(org.id)
             )

    other =
      %Custyard.Organization{}
      |> Custyard.Organization.changeset(%{tenant_id: tenant_id(), name: "Other"})
      |> Repo.insert!()

    assert {:error, :conflicting_binding} =
             Acknowledgments.bind(
               local_authority(tenant_id(), "console"),
               "ots.test",
               "org-new",
               other.id
             )

    assert Acknowledgments.get_binding(ack_scope(tenant_id()), "ots.test", "org-new").organization_id ==
             org.id

    assert {:error, _} =
             Acknowledgments.bind(
               local_authority(tenant_id(), "console"),
               " ots.test",
               "org-new",
               org.id
             )
  end

  describe "binding audit" do
    defp binding_audits do
      Repo.all(
        from e in Custyard.AuditEvent, where: e.event_type == :acknowledgment_binding_created
      )
    end

    test "only a real insert is audited, with the staff who made it", %{organization: org} do
      staff = Custyard.Factory.insert_staff_account(tenant_id: tenant_id(), role: "admin")

      assert {:ok, :created, binding} =
               Acknowledgments.bind(
                 Custyard.Scope.for_staff(
                   staff,
                   Custyard.Tenants.get_tenant!(staff.tenant_id)
                 ),
                 "ots.test",
                 "org-audited",
                 org.id
               )

      assert {:ok, :existing, _} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org-audited",
                 org.id
               )

      other = Custyard.Factory.insert_organization(tenant_id: tenant_id())

      assert {:error, :conflicting_binding} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org-audited",
                 other.id
               )

      assert [event] = binding_audits()
      assert event.source == "staff"
      assert event.organization_id == org.id

      assert event.payload == %{
               "actor" => "staff",
               "staff_id" => staff.id,
               "staff_email" => staff.email,
               "source" => "ots.test",
               "source_organization_id" => "org-audited",
               "organization_id" => binding.organization_id
             }
    end

    test "release commands are audited by channel", %{organization: org} do
      assert {:ok, :created, _} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org-cli",
                 org.id
               )

      assert [%{source: "cli", payload: %{"actor" => "cli"} = payload}] = binding_audits()
      refute Map.has_key?(payload, "staff_id")
    end

    test "a missing organization is reported before any insert" do
      assert {:error, :organization_not_found} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org-orphan",
                 999_999_999
               )

      # Beyond signed 64 bits the SQLite driver would raise.
      assert {:error, :organization_not_found} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org-orphan",
                 9_223_372_036_854_775_808
               )

      assert {:error, :organization_not_found} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org-orphan",
                 "99999999999999999999"
               )

      assert Acknowledgments.get_binding(ack_scope(tenant_id()), "ots.test", "org-orphan") == nil
      assert binding_audits() == []
    end

    test "an actor that cannot be recorded is refused before anything is written", %{
      organization: org
    } do
      assert {:error, :unauthorized} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "web"),
                 "ots.test",
                 "org-x",
                 org.id
               )

      assert Acknowledgments.get_binding(ack_scope(tenant_id()), "ots.test", "org-x") == nil
      assert binding_audits() == []
    end

    test "invalid identities are rejected without an audit row", %{organization: org} do
      assert {:error, %Ecto.Changeset{}} =
               Acknowledgments.bind(
                 local_authority(tenant_id(), "cli"),
                 "ots.test",
                 "org\e[31m",
                 org.id
               )

      assert binding_audits() == []
    end
  end

  test "bindings list with organization names, all or per organization", %{organization: org} do
    other =
      Custyard.Factory.insert_organization(tenant_id: tenant_id(), name: "Other organization")

    {:ok, :created, _} =
      Acknowledgments.bind(local_authority(tenant_id(), "cli"), "ots.test", "org-2", other.id)

    assert [
             %{source: "ots.test", source_organization_id: "org-1", organization_name: "Pilot"},
             %{source_organization_id: "org-2", organization_name: "Other organization"}
           ] = Acknowledgments.list_bindings(ack_scope(tenant_id()))

    assert [%{source_organization_id: "org-1", organization_id: id}] =
             Acknowledgments.list_bindings_for_organization(ack_scope(org.tenant_id), org.id)

    assert id == org.id
    # Rows carry the name only, never the organization (and its portal token).
    refute Enum.any?(
             Acknowledgments.list_bindings(ack_scope(tenant_id())),
             &Map.has_key?(&1, :organization)
           )
  end

  test "the same source and submission can belong to independent tenants", %{organization: org} do
    other_tenant = Custyard.Factory.insert_tenant()
    other_org = Custyard.Factory.insert_organization(tenant_id: other_tenant.id)

    assert {:ok, _} =
             Custyard.Factory.create_acknowledgment_binding(%{
               tenant_id: other_tenant.id,
               source: "ots.test",
               source_organization_id: "org-1",
               organization_id: other_org.id
             })

    assert {:ok, first} = Acknowledgments.ingest(org.tenant_id, evidence())
    assert {:ok, second} = Acknowledgments.ingest(other_tenant.id, evidence())
    refute first.id == second.id
    assert first.organization_id == org.id
    assert second.organization_id == other_org.id
  end

  test "raw tenant ids and ambient actor strings grant no binding authority", %{organization: org} do
    assert {:error, :unauthorized} =
             Acknowledgments.bind(org.tenant_id, "ots.test", "blocked", org.id)

    refute function_exported?(Acknowledgments, :bind, 5)
    refute function_exported?(Acknowledgments, :create_binding, 1)
    assert Acknowledgments.get_binding(ack_scope(org.tenant_id), "ots.test", "blocked") == nil
  end

  test "rejects unsupported, malformed, oversized or altered evidence" do
    for overrides <- [
          %{"schema_version" => 2},
          %{"statement_hash" => String.duplicate("0", 64)},
          %{"actor_type" => "customer"},
          %{"source" => " "},
          %{"source" => "ots.\ttest"},
          %{"actor_id" => "colonel\e[31m"},
          %{"source" => String.duplicate("é", 128)},
          %{"acknowledged_at" => "2026-09-30T12:00:00." <> String.duplicate("0", 100) <> "Z"},
          %{"acknowledged_at" => "2026-09-30T12:00:00+01:00"},
          %{"statement_text" => String.duplicate("a", 16_385)},
          %{"unexpected" => true}
        ] do
      assert {:error, {:invalid_evidence, _}} = Evidence.validate(evidence(overrides))
    end

    assert {:error, {:invalid_evidence, _}} = Evidence.validate(%{})
    assert {:error, {:invalid_evidence, _}} = Evidence.validate(nil)
  end
end

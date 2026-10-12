defmodule Custyard.AcknowledgmentsTest do
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
        "actor_type" => "internal_operator",
        "statement_key" => "example",
        "statement_version" => "v1",
        "statement_text" => text,
        "statement_hash" => Base.encode16(:crypto.hash(:sha256, text), case: :lower),
        "acknowledged_at" => "2026-09-30T12:00:00Z"
      },
      overrides
    )
  end

  setup do
    organization =
      %Custyard.Organization{}
      |> Custyard.Organization.changeset(%{name: "Pilot"})
      |> Repo.insert!()

    {:ok, _} =
      Acknowledgments.create_binding(%{
        source: "ots.test",
        source_organization_id: "org-1",
        organization_id: organization.id
      })

    %{organization: organization}
  end

  test "redelivery preserves exact evidence, receipt time and one record", %{organization: org} do
    payload = evidence()
    assert {:ok, first} = Acknowledgments.ingest(payload)
    assert {:ok, repeated} = Acknowledgments.ingest(payload)
    assert repeated == first
    assert first.statement_text == payload["statement_text"]
    assert first.acknowledged_at == payload["acknowledged_at"]
    assert [^first] = Acknowledgments.list_for_organization(org.id)
  end

  test "conflicting reuse never changes evidence" do
    assert {:ok, first} = Acknowledgments.ingest(evidence())

    assert {:error, :conflicting_submission} =
             Acknowledgments.ingest(evidence(%{"actor_id" => "another"}))

    assert Repo.get!(Custyard.Acknowledgments.Acknowledgment, first.id).actor_id == "colonel-1"
  end

  test "source attribution needs an explicit binding and can recover", %{organization: org} do
    payload = evidence(%{"source" => "ots.other"})
    assert {:error, :unmapped_organization} = Acknowledgments.ingest(payload)

    assert {:ok, _} =
             Acknowledgments.create_binding(%{
               source: "ots.other",
               source_organization_id: "org-1",
               organization_id: org.id
             })

    assert {:ok, _} = Acknowledgments.ingest(payload)

    assert {:error, changeset} =
             Acknowledgments.create_binding(%{
               source: "ots.other",
               source_organization_id: "org-1",
               organization_id: org.id
             })

    refute changeset.valid?
  end

  test "distinct actions survive and listing is bounded", %{organization: org} do
    for n <- 1..3,
        do:
          assert({:ok, _} = Acknowledgments.ingest(evidence(%{"submission_id" => "event-#{n}"})))

    assert length(Acknowledgments.list_for_organization(org.id, limit: 2)) == 2
    assert length(Acknowledgments.list_for_organization(org.id, limit: 2, offset: 2)) == 1
  end

  test "mapping provisioning is idempotent and never reassigns attribution", %{organization: org} do
    assert {:ok, :created, binding} = Acknowledgments.bind("ots.test", "org-new", org.id)
    assert {:ok, :existing, ^binding} = Acknowledgments.bind("ots.test", "org-new", org.id)

    assert {:ok, :existing, ^binding} =
             Acknowledgments.bind("ots.test", "org-new", Integer.to_string(org.id))

    other =
      %Custyard.Organization{}
      |> Custyard.Organization.changeset(%{name: "Other"})
      |> Repo.insert!()

    assert {:error, :conflicting_binding} = Acknowledgments.bind("ots.test", "org-new", other.id)
    assert Acknowledgments.get_binding("ots.test", "org-new").organization_id == org.id
    assert {:error, _} = Acknowledgments.bind(" ots.test", "org-new", org.id)
  end

  describe "binding audit" do
    defp binding_audits do
      Repo.all(
        from e in Custyard.AuditEvent, where: e.event_type == :acknowledgment_binding_created
      )
    end

    test "only a real insert is audited, with the operator who made it", %{organization: org} do
      operator = Custyard.Factory.insert_operator_account()

      assert {:ok, :created, binding} =
               Acknowledgments.bind("ots.test", "org-audited", org.id, operator)

      assert {:ok, :existing, _} = Acknowledgments.bind("ots.test", "org-audited", org.id, "cli")

      other = Custyard.Factory.insert_organization()

      assert {:error, :conflicting_binding} =
               Acknowledgments.bind("ots.test", "org-audited", other.id, "cli")

      assert [event] = binding_audits()
      assert event.source == "operator"
      assert event.organization_id == org.id

      assert event.payload == %{
               "actor" => "operator",
               "operator_id" => operator.id,
               "operator_email" => operator.email,
               "source" => "ots.test",
               "source_organization_id" => "org-audited",
               "organization_id" => binding.organization_id
             }
    end

    test "release commands are audited by channel", %{organization: org} do
      assert {:ok, :created, _} = Acknowledgments.bind("ots.test", "org-cli", org.id, "cli")
      assert [%{source: "cli", payload: %{"actor" => "cli"} = payload}] = binding_audits()
      refute Map.has_key?(payload, "operator_id")
    end

    test "a missing organization is reported before any insert" do
      assert {:error, :organization_not_found} =
               Acknowledgments.bind("ots.test", "org-orphan", 999_999_999, "cli")

      assert Acknowledgments.get_binding("ots.test", "org-orphan") == nil
      assert binding_audits() == []
    end

    test "invalid identities are rejected without an audit row", %{organization: org} do
      assert {:error, %Ecto.Changeset{}} =
               Acknowledgments.bind("ots.test", "org\e[31m", org.id, "cli")

      assert binding_audits() == []
    end
  end

  test "bindings list with organization names, all or per organization", %{organization: org} do
    other = Custyard.Factory.insert_organization(name: "Other organization")
    {:ok, :created, _} = Acknowledgments.bind("ots.test", "org-2", other.id, "cli")

    assert [
             %{source: "ots.test", source_organization_id: "org-1", organization_name: "Pilot"},
             %{source_organization_id: "org-2", organization_name: "Other organization"}
           ] = Acknowledgments.list_bindings()

    assert [%{source_organization_id: "org-1", organization_id: id}] =
             Acknowledgments.list_bindings_for_organization(org.id)

    assert id == org.id
    # Rows carry the name only, never the organization (and its portal token).
    refute Enum.any?(Acknowledgments.list_bindings(), &Map.has_key?(&1, :organization))
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

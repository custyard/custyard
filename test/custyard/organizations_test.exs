defmodule Custyard.OrganizationsTest do
  use Custyard.DataCase, async: true

  alias Custyard.{AuditEvent, Contact, Thread, Organizations, Prospect, Repo, Slugs}
  alias Ecto.Adapters.SQL

  import Custyard.Factory

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)

    Process.put(
      :customer_scope,
      scope(insert_staff_account(role: "admin", tenant_id: tenant.id))
    )

    :ok
  end

  defp scope(staff),
    do: Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))

  defp default_scope, do: Process.get(:customer_scope)

  test "customer public identifiers are generated, immutable and tenant scoped" do
    org = insert_organization()
    other = insert_organization(tenant_id: insert_tenant().id)
    assert {:ok, _} = Ecto.UUID.cast(org.public_id)
    assert org.public_id != other.public_id
    assert Organizations.get_by_public_id(default_scope(), org.public_id).id == org.id
    assert is_nil(Organizations.get_by_public_id(default_scope(), other.public_id))
    assert is_nil(Organizations.get_by_public_id(default_scope(), to_string(org.id)))

    assert {:ok, updated} =
             Organizations.update(default_scope(), org, %{
               public_id: other.public_id,
               name: "Updated"
             })

    assert updated.public_id == org.public_id
  end

  test "database rejects missing and duplicate customer public identifiers" do
    org = insert_organization()
    other = insert_organization()

    for public_id <- [nil, "", other.public_id] do
      assert {:error, _} =
               SQL.query(
                 Repo,
                 "UPDATE organizations SET public_id = ? WHERE id = ?",
                 [public_id, org.id]
               )
    end

    assert Repo.reload!(org).public_id == org.public_id
  end

  describe "get_organization/1" do
    test "returns organization by id" do
      org = insert_organization(name: "Test Org")

      assert result = Organizations.get(default_scope(), org.id)
      assert result.id == org.id
      assert result.name == "Test Org"
    end

    test "returns nil for non-existent id" do
      assert Organizations.get(default_scope(), 999_999) == nil
    end
  end

  describe "get_organization!/1" do
    test "returns organization by id" do
      org = insert_organization(name: "Test Org")

      assert result = Organizations.get!(default_scope(), org.id)
      assert result.id == org.id
    end

    test "raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Organizations.get!(default_scope(), 999_999)
      end
    end
  end

  describe "list_organizations/0" do
    test "returns all organizations ordered by name" do
      insert_organization(name: "Zebra Corp")
      insert_organization(name: "Alpha Inc")
      insert_organization(name: "Beta LLC")

      result = Organizations.list(default_scope())

      assert length(result) == 3
      assert Enum.map(result, & &1.name) == ["Alpha Inc", "Beta LLC", "Zebra Corp"]
    end

    test "returns empty list when no organizations exist" do
      assert Organizations.list(default_scope()) == []
    end
  end

  describe "list_organizations_with_counts/0" do
    test "returns organizations with thread counts" do
      org1 = insert_organization(name: "Org with convos")
      _org2 = insert_organization(name: "Org empty")

      insert_thread(organization_id: org1.id)
      insert_thread(organization_id: org1.id)
      insert_thread(organization_id: org1.id)

      result = Organizations.list_with_counts(default_scope())

      assert length(result) == 2

      org1_result = Enum.find(result, &(&1.org.name == "Org with convos"))
      org2_result = Enum.find(result, &(&1.org.name == "Org empty"))

      assert org1_result.thread_count == 3
      assert org2_result.thread_count == 0
    end
  end

  describe "create_organization/1" do
    test "creates organization with valid attributes" do
      attrs = build_organization(name: "New Corp", tenant_id: insert_tenant().id)

      assert {:ok, org} = Organizations.create(default_scope(), attrs)
      assert org.name == "New Corp"
      assert org.identity_value != nil
    end

    test "returns error changeset for invalid attributes" do
      attrs = %{tier: :standard}

      assert {:error, changeset} = Organizations.create(default_scope(), attrs)
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "update_organization/2" do
    test "updates organization with valid attributes" do
      org = insert_organization(name: "Old Name")

      assert {:ok, updated} = Organizations.update(default_scope(), org, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "returns error for invalid update" do
      org = insert_organization()

      assert {:error, changeset} = Organizations.update(default_scope(), org, %{name: ""})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "change_organization/2" do
    test "returns a changeset" do
      org = insert_organization()

      changeset = Organizations.change_organization(org, %{name: "Changed"})

      assert %Ecto.Changeset{} = changeset
      assert changeset.changes.name == "Changed"
    end
  end

  describe "delete_organization/1" do
    test "deletes the organization" do
      org = insert_organization()

      assert {:ok, deleted} = Organizations.delete(default_scope(), org)
      assert deleted.id == org.id
      assert Organizations.get(default_scope(), org.id) == nil
    end
  end

  describe "convert_prospect/3" do
    setup do
      %{staff: insert_staff_account(role: "admin")}
    end

    test "links the thread to a new organization, keeping :public_intake provenance", %{
      staff: staff
    } do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)

      assert {:ok, converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme Corp"})

      assert converted.source == :public_intake
      assert %{name: "Acme Corp"} = converted.organization
    end

    test "creates a contact from the prospect's captured email", %{staff: staff} do
      thread = insert_thread(source: :public_intake)

      insert_prospect(
        thread_id: thread.id,
        email: "buyer@acme.com",
        email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert {:ok, converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme Corp"})

      assert converted.contact_id
      contact = Repo.get_by!(Contact, organization_id: converted.organization_id)
      assert contact.email == "buyer@acme.com"
    end

    test "no captured email means no contact is created", %{staff: staff} do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)

      assert {:ok, converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme Corp"})

      assert is_nil(converted.contact_id)
      assert Repo.aggregate(Contact, :count) == 0
    end

    test "promotes the thread's confirmed slug claim to provisioned", %{staff: staff} do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)
      {:ok, _slug, token} = Slugs.claim("acme-hq", "buyer@example.com", thread)
      {:ok, _confirmed} = Slugs.confirm(token, Process.get(:factory_tenant_id))

      assert {:ok, converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme Corp"})

      slug = Repo.get_by!(Custyard.Slug, thread_id: thread.id)
      assert slug.status == :provisioned
      assert slug.organization_id == converted.organization_id
    end

    test "an unconfirmed claim is not promoted, but conversion still succeeds", %{
      staff: staff
    } do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)
      {:ok, _slug, _token} = Slugs.claim("still-pending", "buyer@example.com", thread)

      assert {:ok, _converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme"})

      slug = Repo.get_by!(Custyard.Slug, thread_id: thread.id)
      assert slug.status == :claimed
    end

    test "does not revoke or rotate thread access", %{staff: staff} do
      thread = insert_thread(source: :public_intake)
      prospect = insert_prospect(thread_id: thread.id)

      assert {:ok, _converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme"})

      reloaded = Repo.get!(Prospect, prospect.id)
      assert reloaded.access_token_hash == prospect.access_token_hash
      assert is_nil(reloaded.revoked_at)
    end

    test "records a :prospect_converted audit event attributed to the staff", %{
      staff: staff
    } do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)

      assert {:ok, converted} =
               Organizations.convert(scope(staff), thread, %{name: "Acme"})

      event =
        Repo.get_by!(AuditEvent,
          thread_id: converted.id,
          event_type: :prospect_converted
        )

      assert event.organization_id == converted.organization_id
      assert event.payload["staff_id"] == staff.id
      assert event.payload["staff_email"] == staff.email
    end

    test "refuses a thread already linked to an organization", %{staff: staff} do
      org = insert_organization()
      thread = insert_thread(organization_id: org.id, source: :public_intake)

      assert {:error, :not_convertible} =
               Organizations.convert(scope(staff), thread, %{name: "Someone Else"})
    end

    test "refuses a non-public-intake thread", %{staff: staff} do
      thread = insert_thread(organization_id: nil, source: :disambiguation)

      assert {:error, :not_convertible} =
               Organizations.convert(scope(staff), thread, %{name: "Someone Else"})
    end

    test "a genuine step-2 failure compensates the organization, thread stays unlinked", %{
      staff: staff
    } do
      thread = insert_thread(source: :public_intake)

      # Bypasses Prospect's changeset validation (mirrors the factory's raw-struct
      # discipline) to force a real Contact changeset error inside the transaction.
      insert_prospect(
        thread_id: thread.id,
        email: "not-an-email",
        email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert {:error, %Ecto.Changeset{}} =
               Organizations.convert(scope(staff), thread, %{name: "Bad Email Co"})

      assert Organizations.list(default_scope()) == []
      refute Repo.get!(Thread, thread.id).organization_id
    end

    test "a concurrent conversion attempt loses the race and compensates its organization", %{
      staff: staff
    } do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)

      assert {:ok, _first} =
               Organizations.convert(scope(staff), thread, %{name: "First Corp"})

      # Simulates a second staff whose in-memory thread struct was
      # loaded before the first conversion committed (organization_id still nil).
      assert {:error, :already_converted} =
               Organizations.convert(scope(staff), thread, %{name: "Second Corp"})

      assert [remaining] = Organizations.list(default_scope())
      assert remaining.name == "First Corp"
    end
  end
end

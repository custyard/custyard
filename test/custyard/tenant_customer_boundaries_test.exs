defmodule Custyard.TenantCustomerBoundariesTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  alias Custyard.{
    Contact,
    Conversation,
    InboundChannel,
    Organization,
    Organizations,
    Project,
    Scope,
    Settings,
    Task
  }

  test "tenant settings cannot affect another tenant's score or intake configuration" do
    a = insert_tenant()
    b = insert_tenant()

    assert {:ok, _} =
             Settings.update_intake_config(Custyard.Factory.staff_scope(a.id), %{
               unlinked_tier_score: 77
             })

    assert Settings.get_intake_config(a.id).unlinked_tier_score == 77
    assert Settings.get_intake_config(b.id).unlinked_tier_score == 10
    assert Settings.get(a.id).id != Settings.get(b.id).id
  end

  test "scope APIs do not reveal customers from another workspace" do
    a = insert_organization()
    b = insert_organization(tenant_id: insert_tenant().id)

    scope =
      Scope.for_staff(
        insert_staff_account(role: "admin", tenant_id: a.tenant_id),
        Custyard.Tenants.get_tenant!(a.tenant_id)
      )

    assert [customer] = Organizations.list(scope)
    assert customer.id == a.id
    assert is_nil(Organizations.get(scope, b.id))

    assert {:ok, created} =
             Organizations.create(scope, %{name: "Created", tenant_id: b.tenant_id})

    assert created.tenant_id == a.tenant_id
  end

  test "revoked and demoted staff scopes cannot read or mutate tenant resources" do
    org = insert_organization()
    thread = insert_conversation(organization_id: org.id)
    project = insert_project(organization_id: org.id)
    staff = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    scope = Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))

    staff
    |> Ecto.Changeset.change(session_claim: Custyard.StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert Organizations.list(scope) == []
    assert is_nil(Organizations.get(scope, org.id))
    assert is_nil(Custyard.Projects.get(scope, project.id))
    assert is_nil(Custyard.Conversations.get_with_messages(scope, thread.id))
    assert {:error, :unauthorized} = Organizations.update(scope, org, %{name: "Forbidden"})

    assert {:error, :unauthorized} =
             Custyard.Conversations.with_access(scope, thread.id, fn _, _ ->
               flunk("revoked scope")
             end)

    fresh = Repo.reload!(staff)
    scope = Scope.for_staff(fresh, Custyard.Tenants.get_tenant!(org.tenant_id))
    fresh |> Custyard.StaffAccount.role_changeset(%{role: "agent"}) |> Repo.update!()
    assert Organizations.list(scope) == []

    assert {:error, :unauthorized} =
             Custyard.Projects.update(scope, project, %{title: "Forbidden"})
  end

  test "contacts, threads, projects and tasks reject a customer from another tenant" do
    org = insert_organization()
    other = insert_tenant()

    refute Contact.changeset(%Contact{}, %{
             tenant_id: other.id,
             organization_id: org.id,
             email: "alice@example.com"
           }).valid?

    refute Conversation.changeset(%Conversation{}, %{
             tenant_id: other.id,
             organization_id: org.id,
             subject: "Wrong workspace"
           }).valid?

    refute Project.changeset(%Project{}, %{
             tenant_id: other.id,
             organization_id: org.id,
             title: "Wrong workspace"
           }).valid?

    refute Task.changeset(%Task{}, %{
             tenant_id: other.id,
             organization_id: org.id,
             title: "Wrong workspace"
           }).valid?
  end

  test "channels reject routing hints from another tenant" do
    route = insert_inbound_route()
    foreign = insert_organization(tenant_id: insert_tenant().id)

    changeset =
      InboundChannel.changeset(%InboundChannel{}, %{
        tenant_id: route.tenant_id,
        inbound_route_id: route.id,
        public_address: "support@example.com",
        default_organization_id: foreign.id
      })

    refute changeset.valid?
    assert errors_on(changeset).default_organization_id == ["must belong to the same tenant"]
  end

  test "customer deletion removes owned work and keeps tenant infrastructure and audit" do
    org = insert_organization()
    other = insert_organization()
    staff = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    scope = Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))
    contact = insert_contact(organization_id: org.id)
    thread = insert_conversation(organization_id: org.id, contact_id: contact.id)
    message = insert_message(conversation_id: thread.id)
    project = insert_project(organization_id: org.id, conversation_id: thread.id)

    task =
      insert_task(organization_id: org.id, conversation_id: thread.id, project_id: project.id)

    event =
      insert_audit_event(
        organization_id: org.id,
        conversation_id: thread.id,
        project_id: project.id
      )

    channel =
      insert_inbound_channel(
        tenant_id: org.tenant_id,
        default_organization_id: org.id,
        default_project_id: project.id
      )

    assert {:ok, credential, _} = Custyard.PortalCredentials.issue(scope, org.id, contact.id)
    assert {:ok, _} = Organizations.delete(scope, org)

    for {schema, record} <- [
          {Organization, org},
          {Contact, contact},
          {Conversation, thread},
          {Custyard.Message, message},
          {Project, project},
          {Task, task},
          {Custyard.PortalCredential, credential}
        ],
        do: refute(Repo.get(schema, record.id))

    assert Repo.get(Organization, other.id)
    assert Repo.reload!(channel).tenant_id == org.tenant_id
    assert is_nil(Repo.reload!(channel).default_organization_id)
    assert is_nil(Repo.reload!(channel).default_project_id)
    assert Repo.reload!(event).tenant_id == org.tenant_id
    assert is_nil(Repo.reload!(event).organization_id)
    assert is_nil(Repo.reload!(event).conversation_id)
    assert is_nil(Repo.reload!(event).project_id)
  end

  test "retained acknowledgment evidence prevents customer deletion" do
    org = insert_organization()
    staff = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    scope = Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))

    assert {:ok, _} =
             Custyard.Factory.create_acknowledgment_binding(%{
               tenant_id: org.tenant_id,
               source: "test",
               source_organization_id: "customer",
               organization_id: org.id
             })

    text = "Retained statement"

    payload = %{
      "schema_version" => 1,
      "source" => "test",
      "submission_id" => "one",
      "organization_id" => "customer",
      "actor_id" => "actor",
      "actor_role" => "admin",
      "actor_type" => "internal_staff",
      "statement_key" => "consent",
      "statement_version" => "1",
      "statement_text" => text,
      "statement_hash" => Base.encode16(:crypto.hash(:sha256, text), case: :lower),
      "acknowledged_at" => "2026-10-28T00:00:00Z"
    }

    assert {:ok, evidence} = Custyard.Acknowledgments.ingest(org.tenant_id, payload)
    assert {:error, :retained_evidence} = Organizations.delete(scope, org)
    assert Repo.get(Organization, org.id)
    assert Repo.reload!(evidence).organization_id == org.id
  end

  test "threads reject another customer's contact and project inside the same tenant" do
    own = insert_organization()
    other = insert_organization()
    contact = insert_contact(organization_id: other.id)
    project = insert_project(organization_id: other.id)

    changeset =
      Conversation.changeset(%Conversation{}, %{
        tenant_id: own.tenant_id,
        organization_id: own.id,
        subject: "Invalid customer links",
        contact_id: contact.id,
        project_id: project.id
      })

    assert errors_on(changeset).contact_id == ["must belong to the thread's customer"]
    assert errors_on(changeset).project_id == ["must belong to the thread's customer"]
  end

  test "manual customer identities remain independent when names are equal" do
    tenant = insert_tenant()

    a =
      %Organization{}
      |> Organization.changeset(%{tenant_id: tenant.id, name: "Same name"})
      |> Repo.insert!()

    b =
      %Organization{}
      |> Organization.changeset(%{tenant_id: tenant.id, name: "Same name"})
      |> Repo.insert!()

    assert a.identity_kind == :manual
    refute a.identity_value == b.identity_value
  end
end

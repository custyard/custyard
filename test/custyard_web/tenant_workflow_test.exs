defmodule CustyardWeb.TenantWorkflowTest do
  use CustyardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{
    Authorization,
    Conversations,
    Intake,
    OperatorAccount,
    Organizations,
    Repo,
    Tenants
  }

  setup do
    {:ok, atlas} = Tenants.create_tenant(%{name: "Atlas onboarding", slug: "atlas"})
    {:ok, beacon} = Tenants.create_tenant(%{name: "Beacon onboarding", slug: "beacon"})
    {:ok, _} = Tenants.add_host(atlas.id, "atlas.test")
    {:ok, _} = Tenants.add_host(beacon.id, "beacon.test")
    {:ok, atlas: atlas, beacon: beacon}
  end

  test "customers with the same domain are independent across tenants", %{atlas: a, beacon: b} do
    {:ok, acme} =
      create_customer(%{tenant_id: a.id, name: "Acme", domain: "acme.example"})

    assert {:ok, _} =
             create_customer(%{
               tenant_id: b.id,
               name: "Acme",
               domain: "acme.example"
             })

    assert {:error, _} =
             create_customer(%{
               tenant_id: a.id,
               name: "Duplicate",
               domain: "acme.example"
             })

    assert {:error, _} = Organizations.update(scope_for(a), acme, %{tenant_id: b.id})
  end

  test "tenant staff work across customers and unlinked intake but cannot read another tenant", %{
    conn: conn,
    atlas: a,
    beacon: b
  } do
    acme = insert_organization(tenant_id: a.id, name: "Acme A")
    beta = insert_organization(tenant_id: a.id, name: "Beta A")
    other = insert_organization(tenant_id: b.id)
    c1 = insert_conversation(organization_id: acme.id, subject: "Acme visible")
    c2 = insert_conversation(organization_id: beta.id, subject: "Beta visible")
    c3 = insert_conversation(organization_id: other.id, subject: "Foreign hidden")

    {:ok, source} =
      Intake.create_source(Custyard.Scope.for_staff(staff(a, "admin"), a), %{
        key: "atlas-entry",
        name: "Atlas",
        tenant_id: a.id
      })

    {:ok, %{conversation: public}} =
      Intake.create_intake_conversation(source.key, "Public onboarding", tenant_id: a.id)

    op = staff(a)
    assert Authorization.can_access_conversation?(op, c1)
    assert Authorization.can_access_conversation?(op, c2)
    assert Authorization.can_access_conversation?(op, public)
    refute Authorization.can_access_conversation?(op, c3)

    assert MapSet.new(
             Enum.map(
               Conversations.list(Custyard.Scope.for_staff(op, a)),
               & &1.conversation.id
             )
           ) == MapSet.new([c1.id, c2.id, public.id])

    conn = conn |> init_test_session(%{}) |> put_operator_session(op)
    {:ok, _view, html} = live(conn, "/app")
    assert html =~ "Acme visible"
    assert html =~ "Beta visible"
    refute html =~ "Foreign hidden"
    assert {:error, {:redirect, _}} = live(conn, "/app/threads/#{c3.id}")
  end

  test "private public conversation URL stays available, branded, and constrained by tenant host",
       %{conn: conn, atlas: a, beacon: b} do
    {:ok, source} =
      Intake.create_source(Custyard.Scope.for_staff(staff(a, "admin"), a), %{
        key: "atlas-public",
        name: "Atlas",
        tenant_id: a.id
      })

    {:ok, %{conversation: conversation, access_token: token}} =
      Intake.create_intake_conversation(source.key, "A private onboarding question",
        tenant_id: a.id
      )

    assert conversation.tenant_id == a.id
    {:ok, _view, html} = live(%{conn | host: Tenants.host(a)}, "/threads/#{token}")
    assert html =~ "Atlas onboarding"
    assert html =~ "A private onboarding question"

    assert {:error, {:redirect, %{to: "/threads/unavailable"}}} =
             live(%{build_conn() | host: Tenants.host(b)}, "/threads/#{token}")

    assert get(%{build_conn() | host: Tenants.host(b)}, "/intake/#{source.key}").status == 404
  end

  test "customer portal token keeps each customer's threads private on a tenant domain", %{
    conn: conn,
    atlas: a,
    beacon: b
  } do
    acme = insert_organization(tenant_id: a.id, name: "Acme")
    beta = insert_organization(tenant_id: a.id, name: "Beta")
    insert_conversation(organization_id: acme.id, subject: "Acme private")
    insert_conversation(organization_id: beta.id, subject: "Beta private")
    {:ok, _view, html} = live(%{conn | host: Tenants.host(a)}, "/portal/#{portal_token(acme)}")
    assert html =~ "Atlas onboarding"
    assert html =~ "Acme private"
    refute html =~ "Beta private"

    assert get(%{build_conn() | host: Tenants.host(b)}, "/portal/#{portal_token(acme)}").status ==
             404
  end

  test "tenant administrator cannot create an instance administrator by forging role", %{
    conn: conn,
    atlas: a
  } do
    op = staff(a, "admin")
    conn = conn |> init_test_session(%{}) |> put_operator_session(op)
    {:ok, view, _} = live(conn, "/app/settings/workspace")

    render_submit(view, "invite", %{
      "staff" => %{"email" => "forged@example.net", "role" => "super_admin"}
    })

    refute Repo.get_by(OperatorAccount, email: "forged@example.net")
  end

  test "capturing a public sender email cannot link to another tenant customer", %{
    atlas: a,
    beacon: b
  } do
    other = insert_organization(tenant_id: b.id)
    contact = insert_contact(organization_id: other.id, email: "alice@shared.example")

    {:ok, source} =
      Intake.create_source(Custyard.Scope.for_staff(staff(a, "admin"), a), %{
        key: "atlas-capture",
        name: "Atlas",
        tenant_id: a.id
      })

    {:ok, %{conversation: conversation}} =
      Intake.create_intake_conversation(source.key, "Question", tenant_id: a.id)

    assert {:ok, captured} = Intake.capture_email(conversation, contact.email)
    assert captured.organization_id == nil
    assert captured.tenant_id == a.id
  end

  defp scope_for(tenant), do: Custyard.Scope.for_staff(staff(tenant, "admin"), tenant)

  defp create_customer(attrs),
    do: Organizations.create(scope_for(Tenants.get_tenant!(attrs.tenant_id)), attrs)

  defp staff(tenant, role \\ "agent") do
    %OperatorAccount{}
    |> OperatorAccount.changeset(%{
      email: "#{role}-#{tenant.slug}-#{System.unique_integer([:positive])}@staff.example",
      role: role,
      tenant_id: tenant.id
    })
    |> Repo.insert!()
  end
end

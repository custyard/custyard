defmodule CustyardWeb.Operator.EmailSetupLiveTest do
  use CustyardWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{EmailSetup, Repo, Tenant}

  setup %{conn: conn} do
    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          name: "North support",
          slug: "north-#{System.unique_integer([:positive])}"
        })
      )

    operator = insert_operator_account(role: "admin", tenant_id: tenant.id)
    conn = conn |> init_test_session(%{}) |> put_operator_session(operator)
    %{conn: conn, tenant: tenant, operator: operator}
  end

  test "resumable setup explains empty prerequisites and never re-renders submitted secrets", c do
    {:ok, view, html} = live(c.conn, ~p"/operator/email-setup")
    assert html =~ "North support"
    assert has_element?(view, "button[phx-click=new_channel][disabled]")
    assert html =~ "Import a real receiving route"
    assert html =~ "Reply accepted by provider"

    html =
      view
      |> form("#email-credentials",
        connection: %{
          project_id: "project-1",
          project_token: "private-project-token",
          team_token: "private-team-token"
        }
      )
      |> render_submit()

    refute html =~ "private-project-token"
    refute html =~ "private-team-token"
    assert has_element?(view, "input[name='connection[project_token]'][value='']")
    assert EmailSetup.connection(c.tenant.id).project_id == "project-1"
    {:ok, _reopened, html} = live(c.conn, ~p"/operator/email-setup")
    assert html =~ "project-1"
    refute html =~ "private-project-token"
  end

  test "an agent cannot open setup or mutate credentials", c do
    agent = insert_operator_account(role: "agent", tenant_id: c.tenant.id)
    conn = c.conn |> put_operator_session(agent)
    assert {:error, {:redirect, _}} = live(conn, ~p"/operator/email-setup")

    assert {:error, :unauthorized} =
             EmailSetup.save_credentials(agent, c.tenant.id, %{"team_token" => "forged"})

    assert is_nil(EmailSetup.connection(c.tenant.id))
  end

  test "resuming a channel and adding another address show the correct wizard", c do
    route = insert_inbound_route(tenant_id: c.tenant.id, organization_id: nil)

    channel =
      insert_inbound_channel(
        tenant_id: c.tenant.id,
        organization_id: nil,
        inbound_route_id: route.id,
        state: :active
      )

    {:ok, view, _} = live(c.conn, ~p"/operator/email-setup")
    render_click(view, "resume_channel", %{"id" => to_string(channel.id)})
    assert has_element?(view, "[data-testid=channel-reply-step]")
    refute has_element?(view, "#channel-create-form")

    render_click(view, "new_channel")
    assert has_element?(view, "#channel-create-form")
    refute has_element?(view, "[data-testid=channel-reply-step]")
  end

  test "an open channel component cannot mutate after its administrator is demoted", c do
    route = insert_inbound_route(tenant_id: c.tenant.id, organization_id: nil)

    channel =
      insert_inbound_channel(
        tenant_id: c.tenant.id,
        organization_id: nil,
        inbound_route_id: route.id,
        state: :active,
        archive_copy: false
      )

    {:ok, view, _} = live(c.conn, ~p"/operator/email-setup")
    render_click(view, "resume_channel", %{"id" => to_string(channel.id)})
    assert has_element?(view, "[data-testid=channel-archive-copy-toggle]")
    Repo.update!(Custyard.OperatorAccount.role_changeset(c.operator, %{role: "agent"}))

    view |> element("[data-testid=channel-archive-copy-toggle]") |> render_click()
    assert_redirect(view, "/operator")

    refute Repo.reload!(channel).archive_copy
  end
end

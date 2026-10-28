defmodule CustyardWeb.Operator.TenantControllerTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Phoenix.LiveViewTest

  alias Custyard.{OperatorAccount, Repo, Tenants}

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Host tenant",
        slug: "switch-#{suffix}",
        custom_domain: "switch-#{suffix}.tenant.example"
      })

    {:ok, target} =
      Tenants.create_tenant(%{name: "Selected workspace", slug: "target-#{suffix}"})

    %{tenant: tenant, target: target, operator: insert_operator_account()}
  end

  test "instance-host selection changes the session and opens the selected workspace", c do
    selected =
      c.conn
      |> init_test_session(%{})
      |> put_operator_session(c.operator)
      |> post("/operator/tenants/#{c.target.id}/select")

    assert redirected_to(selected) == "/operator"
    assert get_session(selected, :selected_tenant_id) == c.target.id
    {:ok, _view, html} = live(recycle(selected), "/operator/tenant")
    assert html =~ c.target.name
  end

  test "tenant-host selection moves to the instance console without pretending to switch", c do
    for host <- [c.tenant.custom_domain, c.tenant.slug <> "." <> Tenants.app_host()] do
      selected =
        %{build_conn() | host: host}
        |> init_test_session(%{selected_tenant_id: c.tenant.id})
        |> put_operator_session(c.operator)
        |> post("/operator/tenants/#{c.target.id}/select", %{
          "return_to" => "https://attacker.example/operator",
          "host" => "attacker.example"
        })

      assert redirected_to(selected) ==
               CustyardWeb.Endpoint.url() <> "/operator/tenants?switch=required"

      assert get_session(selected, :selected_tenant_id) == c.tenant.id

      {:ok, view, _} =
        live(
          %{build_conn() | host: host}
          |> init_test_session(%{})
          |> put_operator_session(c.operator),
          "/operator/tenants"
        )

      assert has_element?(view, "[role=status]", "Switch tenants on the instance console")

      assert has_element?(
               view,
               "a[href='#{CustyardWeb.Endpoint.url()}/operator/tenants']",
               "Open instance console"
             )

      refute has_element?(view, "a[data-method=post]")
      refute has_element?(view, "#tenant-create")
    end
  end

  test "the instance console explains how to finish switching", c do
    {:ok, view, _} =
      c.conn
      |> init_test_session(%{})
      |> put_operator_session(c.operator)
      |> live("/operator/tenants?switch=required")

    assert has_element?(view, "[role=status]", "Select a tenant here to finish switching")

    assert has_element?(
             view,
             "a[data-method=post][href='/operator/tenants/#{c.target.id}/select']"
           )
  end

  test "tenant staff cannot select another workspace", c do
    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{
        email: "agent@switch.example",
        role: "agent",
        tenant_id: c.tenant.id
      })
      |> Repo.insert!()

    denied =
      c.conn
      |> init_test_session(%{})
      |> put_operator_session(operator)
      |> post("/operator/tenants/#{c.target.id}/select")

    assert response(denied, 403) == "Forbidden"
    refute get_session(denied, :selected_tenant_id)
  end

  test "malformed and missing tenant ids cannot redirect to an untrusted host", c do
    for id <- ["99999999", "https://attacker.example"] do
      denied =
        c.conn
        |> init_test_session(%{})
        |> put_operator_session(c.operator)
        |> post("/operator/tenants/#{URI.encode_www_form(id)}/select")

      assert response(denied, 404) == "Not found"
      refute get_session(denied, :selected_tenant_id)
    end
  end
end

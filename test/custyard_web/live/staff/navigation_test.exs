defmodule CustyardWeb.Staff.NavigationTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Custyard.{StaffAccount, Repo}

  setup %{conn: conn} do
    # Create and authenticate a staff
    {:ok, staff} =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        role: "admin",
        tenant_id: Process.get(:factory_tenant_id),
        email: "test@example.com",
        password: "password123"
      })
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff.id)

    {:ok, conn: conn, staff: staff}
  end

  describe "staff navigation" do
    test "keeps every destination and the account group", %{conn: conn, staff: staff} do
      {:ok, view, _html} = live(conn, ~p"/app")

      for {testid, text, href} <- [
            {"staff-nav-queue", "Attention Queue", "/app"},
            {"staff-nav-neglect", "Neglect Report", "/app/neglect"},
            {"staff-nav-orgs", "Customers", "/app/customers"},
            {"staff-nav-projects", "Projects", "/app/projects"},
            {"staff-nav-intake-sources", "Intake Sources", "/app/settings/intake"},
            {"staff-nav-slugs", "Slugs", "/app/settings/slugs"},
            {"staff-nav-acknowledgments", "Acknowledgments", "/app/settings/integrations"},
            {"staff-nav-settings", "Settings", "/app/settings/workflow"}
          ] do
        assert has_element?(
                 view,
                 "nav[aria-label=Staff] a[data-testid=#{testid}][href='#{href}']",
                 text
               )
      end

      assert has_element?(view, "[data-testid=staff-identity]", "Staff · #{staff.email}")

      # Shown as an icon on narrower screens; the name is still its text.
      assert has_element?(
               view,
               "a[data-testid=staff-nav-instance-admin][href$='/admin/login'][title='Instance admin sign in']",
               "Instance admin sign in"
             )

      assert has_element?(view, "a[data-testid=staff-nav-logout][href='/app/logout']", "Log out")

      assert has_element?(
               view,
               "#mobile-menu a[data-testid=staff-nav-mobile-instance-admin][href$='/admin/login']",
               "Instance admin sign in"
             )
    end
  end
end

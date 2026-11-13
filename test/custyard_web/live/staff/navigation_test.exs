defmodule CustyardWeb.Staff.NavigationTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  @top "nav[aria-label=Staff]"
  @second "nav[data-testid=staff-subnav]"

  defp sign_in(conn, role) do
    staff = insert_staff_account(role: role)
    conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> put_staff_session(staff)
    %{conn: conn, staff: staff}
  end

  # The links inside `selector`, in order: {test id, text, href, aria-current}.
  defp links(view, selector) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("#{selector} a")
    |> Enum.map(fn link ->
      {
        link |> Floki.attribute("data-testid") |> List.first(),
        link |> Floki.text() |> String.trim(),
        link |> Floki.attribute("href") |> List.first(),
        link |> Floki.attribute("aria-current") |> List.first()
      }
    end)
  end

  defp second_row(view),
    do: for({testid, _, _, current} <- links(view, @second), do: {testid, current})

  defp active_top(view),
    do: for({testid, _, _, current} when current != nil <- links(view, @top), do: testid)

  describe "top level for an admin" do
    setup %{conn: conn}, do: sign_in(conn, "admin")

    test "lists the four sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app")

      assert links(view, @top) == [
               {"staff-nav-queue", "Attention Queue", "/app", "page"},
               {"staff-nav-orgs", "Customers", "/app/customers", nil},
               {"staff-nav-projects", "Projects", "/app/projects", nil},
               {"staff-nav-settings", "Settings", "/app/settings/workflow", nil}
             ]
    end

    test "the pages that moved down have no top-level link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app")

      for testid <- ~w(staff-nav-neglect staff-nav-intake-sources staff-nav-slugs
                       staff-nav-acknowledgments staff-nav-mobile-acknowledgments) do
        refute html =~ ~s(data-testid="#{testid}")
      end
    end

    test "the mobile menu carries the same sections and the account links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/customers")

      assert [
               {"staff-nav-mobile-queue", "Attention Queue", "/app", nil},
               {"staff-nav-mobile-orgs", "Customers", "/app/customers", "page"},
               {"staff-nav-mobile-projects", "Projects", "/app/projects", nil},
               {"staff-nav-mobile-settings", "Settings", "/app/settings/workflow", nil},
               {"staff-nav-mobile-instance-admin", "Instance admin sign in", admin_href, nil},
               {nil, "Log out", "/app/logout", nil}
             ] = links(view, "#mobile-menu")

      assert String.ends_with?(admin_href, "/admin/login")
    end

    test "keeps the account group", %{conn: conn, staff: staff} do
      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(view, "[data-testid=staff-identity]", "Staff · #{staff.email}")

      # Shown as an icon on narrower screens; the name is still its text.
      assert has_element?(
               view,
               "a[data-testid=staff-nav-instance-admin][href$='/admin/login'][title='Instance admin sign in']",
               "Instance admin sign in"
             )

      assert has_element?(view, "a[data-testid=staff-nav-logout][href='/app/logout']", "Log out")
      assert has_element?(view, "button[data-testid=staff-nav-mobile-toggle]")
    end
  end

  describe "top level for an agent" do
    setup %{conn: conn}, do: sign_in(conn, "agent")

    test "leaves out Settings, which only admins can open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app")

      assert links(view, @top) == [
               {"staff-nav-queue", "Attention Queue", "/app", "page"},
               {"staff-nav-orgs", "Customers", "/app/customers", nil},
               {"staff-nav-projects", "Projects", "/app/projects", nil}
             ]

      refute has_element?(view, "#mobile-menu [data-testid=staff-nav-mobile-settings]")
    end
  end

  describe "active section and second row for an admin" do
    setup %{conn: conn}, do: sign_in(conn, "admin")

    test "attention queue pages", %{conn: conn} do
      thread = insert_thread()

      for {path, row} <- [
            {~p"/app", [queue: "page", tasks: nil, neglect: nil]},
            {~p"/app/tasks", [queue: nil, tasks: "page", neglect: nil]},
            {~p"/app/neglect", [queue: nil, tasks: nil, neglect: "page"]},
            # A thread is opened from the queue, so the queue is marked as
            # its place without claiming to be the page on screen.
            {~p"/app/threads/#{thread.id}", [queue: "true", tasks: nil, neglect: nil]}
          ] do
        {:ok, view, _html} = live(conn, path)

        assert active_top(view) == ["staff-nav-queue"], path

        assert second_row(view) ==
                 for({id, current} <- row, do: {"staff-subnav-#{id}", current}),
               path
      end
    end

    test "the second row names its pages in sentence case", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/neglect")

      assert has_element?(view, "#{@second}[aria-label='Attention Queue']")

      assert links(view, @second) == [
               {"staff-subnav-queue", "Queue", "/app", nil},
               {"staff-subnav-tasks", "All tasks", "/app/tasks", nil},
               {"staff-subnav-neglect", "Neglect report", "/app/neglect", "page"}
             ]
    end

    test "customers pages", %{conn: conn} do
      org = insert_organization()

      for {path, row} <- [
            {~p"/app/customers", [customers: "page", acknowledgments: nil, slugs: nil]},
            {~p"/app/customers/#{org.public_id}",
             [customers: "true", acknowledgments: nil, slugs: nil]},
            {~p"/app/customers/acknowledgments",
             [customers: nil, acknowledgments: "page", slugs: nil]},
            {~p"/app/customers/slugs", [customers: nil, acknowledgments: nil, slugs: "page"]}
          ] do
        {:ok, view, _html} = live(conn, path)

        assert active_top(view) == ["staff-nav-orgs"], path

        assert second_row(view) ==
                 for({id, current} <- row, do: {"staff-subnav-#{id}", current}),
               path
      end
    end

    test "projects has one page, so no second row", %{conn: conn} do
      project = insert_project()

      for path <- [~p"/app/projects", ~p"/app/projects/#{project.id}"] do
        {:ok, view, _html} = live(conn, path)

        assert active_top(view) == ["staff-nav-projects"], path
        refute has_element?(view, @second), path
      end
    end

    test "settings pages", %{conn: conn} do
      for {path, current} <- [
            {~p"/app/settings/workflow", :workflow},
            {~p"/app/settings/email", :email},
            {~p"/app/settings/intake", :intake},
            {~p"/app/settings/tenant", :tenant},
            {~p"/app/settings/audit", :audit}
          ] do
        {:ok, view, _html} = live(conn, path)

        assert active_top(view) == ["staff-nav-settings"], path

        assert second_row(view) ==
                 for(
                   id <- [:workflow, :email, :intake, :tenant, :audit],
                   do: {"staff-subnav-#{id}", if(id == current, do: "page")}
                 ),
               path
      end
    end

    test "settings links show on a settings page and not on the queue", %{conn: conn} do
      {:ok, settings, _html} = live(conn, ~p"/app/settings/workflow")

      assert has_element?(
               settings,
               "#{@second} a[data-testid=staff-subnav-email][href='/app/settings/email']",
               "Support email setup"
             )

      assert has_element?(
               settings,
               "#{@second} a[data-testid=staff-subnav-tenant][href='/app/settings/tenant']",
               "Tenant settings"
             )

      {:ok, queue, html} = live(conn, ~p"/app")

      refute html =~ "Support email setup"
      refute html =~ "Tenant settings"
      refute has_element?(queue, "[data-testid=staff-subnav-email]")
      refute has_element?(queue, "[data-testid=staff-subnav-tenant]")
      refute has_element?(queue, "a[href='/app/settings/tenant']")
    end

    # The thread page fills the height left under the navigation. That holds
    # while the second row is a row of the layout column and the thread page
    # is the only thing in the content area.
    test "the second row sits outside the content area on the thread page", %{conn: conn} do
      thread = insert_thread()
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{thread.id}")

      assert has_element?(view, "[data-testid=staff-layout].flex.flex-col.h-screen > #{@second}")

      assert has_element?(
               view,
               "[data-testid=staff-layout] > [data-testid=staff-layout-content].flex-1.min-h-0 > [data-testid=staff-thread-page].flex-1.min-h-0"
             )

      refute has_element?(view, "[data-testid=staff-layout-content] #{@second}")
    end
  end

  describe "second row for an agent" do
    setup %{conn: conn}, do: sign_in(conn, "agent")

    test "shows the attention queue pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/neglect")

      assert second_row(view) == [
               {"staff-subnav-queue", nil},
               {"staff-subnav-tasks", nil},
               {"staff-subnav-neglect", "page"}
             ]
    end

    test "hides the admin-only customer pages, which leaves no second row", %{conn: conn} do
      org = insert_organization()

      for path <- [~p"/app/customers", ~p"/app/customers/#{org.public_id}"] do
        {:ok, view, html} = live(conn, path)

        assert active_top(view) == ["staff-nav-orgs"], path
        refute has_element?(view, @second), path
        refute html =~ "staff-subnav-acknowledgments"
        refute html =~ "staff-subnav-slugs"
      end
    end

    test "never shows a settings link", %{conn: conn} do
      for path <- [~p"/app", ~p"/app/customers", ~p"/app/projects"] do
        {:ok, _view, html} = live(conn, path)

        refute html =~ "/app/settings/"
      end
    end
  end
end

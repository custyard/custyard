defmodule CustyardWeb.StaffNavTest do
  use ExUnit.Case, async: true

  alias CustyardWeb.Staff
  alias CustyardWeb.StaffNav

  defp labels(links), do: Enum.map(links, & &1.label)
  defp current(links), do: for(%{current: value} = link when value != nil <- links, do: link.id)

  describe "top_level/2" do
    test "an admin sees the four sections in order" do
      links = StaffNav.top_level("admin", Staff.AttentionQueueLive)

      assert Enum.map(links, &{&1.label, &1.path, &1.testid}) == [
               {"Attention Queue", "/app", "queue"},
               {"Customers", "/app/customers", "orgs"},
               {"Projects", "/app/projects", "projects"},
               {"Settings", "/app/settings/workflow", "settings"}
             ]
    end

    test "an agent does not see Settings, which has no page for them" do
      links = StaffNav.top_level("agent", Staff.AttentionQueueLive)

      assert labels(links) == ["Attention Queue", "Customers", "Projects"]
    end

    test "marks the section that holds the page on screen" do
      for {view, section} <- [
            {Staff.AttentionQueueLive, :queue},
            {Staff.ThreadLive, :queue},
            {Staff.TasksLive, :queue},
            {Staff.NeglectReportLive, :queue},
            {Staff.OrganizationsLive, :customers},
            {Staff.OrganizationDetailLive, :customers},
            {Staff.AcknowledgmentsLive, :customers},
            {Staff.SlugsLive, :customers},
            {Staff.ProjectsLive, :projects},
            {Staff.ProjectDetailLive, :projects},
            {Staff.SettingsLive, :settings},
            {Staff.EmailSetupLive, :settings},
            {Staff.IntakeSourcesLive, :settings},
            {Staff.TenantSettingsLive, :settings}
          ] do
        assert current(StaffNav.top_level("admin", view)) == [section],
               "expected #{inspect(view)} to sit in #{section}"
      end
    end

    test "says page only when the link leads to the page on screen" do
      current_value = fn view ->
        Enum.find_value(StaffNav.top_level("admin", view), & &1.current)
      end

      assert current_value.(Staff.AttentionQueueLive) == "page"
      assert current_value.(Staff.NeglectReportLive) == "true"
      assert current_value.(Staff.ThreadLive) == "true"
      assert current_value.(Staff.SettingsLive) == "page"
      assert current_value.(Staff.TenantSettingsLive) == "true"
    end

    test "marks nothing for a LiveView outside the navigation" do
      assert current(StaffNav.top_level("admin", CustyardWeb.HomeLive)) == []
    end
  end

  describe "second_level/2" do
    test "lists the pages of the section on screen and marks the current one" do
      links = StaffNav.second_level("admin", Staff.NeglectReportLive)

      assert Enum.map(links, &{&1.label, &1.path, &1.testid, &1.current}) == [
               {"Queue", "/app", "queue", nil},
               {"All tasks", "/app/tasks", "tasks", nil},
               {"Neglect report", "/app/neglect", "neglect", "page"}
             ]
    end

    test "the customers section holds acknowledgments and slugs for an admin" do
      links = StaffNav.second_level("admin", Staff.SlugsLive)

      assert Enum.map(links, &{&1.label, &1.path, &1.testid, &1.current}) == [
               {"All customers", "/app/customers", "customers", nil},
               {"Acknowledgments", "/app/customers/acknowledgments", "acknowledgments", nil},
               {"Slugs", "/app/customers/slugs", "slugs", "page"}
             ]
    end

    test "the settings section holds the settings pages and the audit log" do
      links = StaffNav.second_level("admin", Staff.SettingsLive)

      assert Enum.map(links, &{&1.label, &1.path, &1.testid}) == [
               {"Workflow", "/app/settings/workflow", "workflow"},
               {"Support email setup", "/app/settings/email", "email"},
               {"Intake sources", "/app/settings/intake", "intake"},
               {"Tenant settings", "/app/settings/tenant", "tenant"},
               {"Audit log", "/app/settings/audit", "audit"}
             ]

      assert current(links) == [:workflow]
    end

    test "a detail view marks the page it was opened from, not as the page itself" do
      thread = StaffNav.second_level("agent", Staff.ThreadLive)
      assert Enum.map(thread, &{&1.id, &1.current}) == [queue: "true", tasks: nil, neglect: nil]

      customer = StaffNav.second_level("admin", Staff.OrganizationDetailLive)
      assert Enum.find(customer, &(&1.id == :customers)).current == "true"
    end

    test "is empty when the viewer sees fewer than two pages of the section" do
      # Projects has one page for everyone.
      assert StaffNav.second_level("admin", Staff.ProjectsLive) == []
      assert StaffNav.second_level("admin", Staff.ProjectDetailLive) == []

      # An agent sees only the list in Customers.
      assert StaffNav.second_level("agent", Staff.OrganizationsLive) == []
      assert StaffNav.second_level("agent", Staff.OrganizationDetailLive) == []
    end

    test "an agent sees every page of the attention queue section" do
      assert labels(StaffNav.second_level("agent", Staff.AttentionQueueLive)) ==
               ["Queue", "All tasks", "Neglect report"]
    end

    test "is empty for a LiveView outside the navigation" do
      assert StaffNav.second_level("admin", CustyardWeb.HomeLive) == []
    end
  end

  describe "sections/0 against the router" do
    # A LiveView in the staff sessions that no section covers would render
    # with nothing marked and no second row.
    test "covers every LiveView in the staff sessions" do
      for {view, _session} <- staff_routes() do
        assert StaffNav.active_section(view), "#{inspect(view)} is in no section"
      end
    end

    test "every page path opens one of the page's own LiveViews" do
      for section <- StaffNav.sections(), page <- section.pages do
        assert {view, _session} = route(page.path)
        assert view in page.views, "#{page.path} opens #{inspect(view)}"
      end
    end

    test "a page is admin only exactly when its route requires an admin" do
      for section <- StaffNav.sections(), page <- section.pages do
        {_view, session} = route(page.path)

        assert page.admin == (session == :staff_admin),
               "#{page.path} is in the #{session} session"
      end
    end

    test "page ids are unique, since they name the second-row test ids" do
      ids = for section <- StaffNav.sections(), page <- section.pages, do: page.id

      assert ids == Enum.uniq(ids)
    end
  end

  defp staff_routes do
    for %{metadata: %{phoenix_live_view: {view, _action, _opts, %{name: session}}}} <-
          CustyardWeb.Router.__routes__(),
        session in [:staff, :staff_admin],
        uniq: true,
        do: {view, session}
  end

  defp route(path) do
    %{phoenix_live_view: {view, _action, _opts, %{name: session}}} =
      Phoenix.Router.route_info(CustyardWeb.Router, "GET", path, "workspace.example.com")

    {view, session}
  end
end

defmodule CustyardWeb.StaffNav do
  @moduledoc """
  The staff navigation, described once.

  `sections/0` is the whole structure: each section, its pages, the LiveViews
  each page covers and who may see it. The top row, the mobile menu and the
  second row (the pages of the section on screen) are all rendered from it,
  so a page is added or moved in one place.

  The grouping follows the data model. See "Staff navigation" in
  docs/entity-relationships.md for the reason behind each placement.
  """
  use CustyardWeb, :html

  alias CustyardWeb.Staff

  @doc """
  Every section in display order.

  A section links to its first page that the viewer may see, and is left out
  when there is none. `:testid` is the end of the link's test id:
  `staff-nav-orgs`, and `staff-nav-mobile-orgs` in the mobile menu.

  A page names the LiveViews that show it in `:views` and the detail views
  opened from it in `:below`. `admin: true` hides the page from agents; its
  route already turns them away. The page id ends the second-row test id:
  `staff-subnav-slugs`.
  """
  def sections do
    [
      %{
        id: :queue,
        label: "Attention Queue",
        testid: "queue",
        pages: [
          page(:queue, "Queue", ~p"/app", [Staff.AttentionQueueLive], below: [Staff.ThreadLive]),
          page(:tasks, "All tasks", ~p"/app/tasks", [Staff.TasksLive]),
          page(:neglect, "Neglect report", ~p"/app/neglect", [Staff.NeglectReportLive])
        ]
      },
      %{
        id: :customers,
        label: "Customers",
        testid: "orgs",
        pages: [
          page(:customers, "All customers", ~p"/app/customers", [Staff.OrganizationsLive],
            below: [Staff.OrganizationDetailLive]
          ),
          page(
            :acknowledgments,
            "Acknowledgments",
            ~p"/app/customers/acknowledgments",
            [Staff.AcknowledgmentsLive],
            admin: true
          ),
          page(:slugs, "Slugs", ~p"/app/customers/slugs", [Staff.SlugsLive], admin: true)
        ]
      },
      %{
        id: :projects,
        label: "Projects",
        testid: "projects",
        pages: [
          page(:projects, "Projects", ~p"/app/projects", [Staff.ProjectsLive],
            below: [Staff.ProjectDetailLive]
          )
        ]
      },
      %{
        id: :settings,
        label: "Settings",
        testid: "settings",
        pages: [
          page(:workflow, "Workflow", ~p"/app/settings/workflow", [Staff.SettingsLive],
            admin: true
          ),
          page(:email, "Support email setup", ~p"/app/settings/email", [Staff.EmailSetupLive],
            admin: true
          ),
          page(:intake, "Intake sources", ~p"/app/settings/intake", [Staff.IntakeSourcesLive],
            admin: true
          ),
          page(
            :tenant,
            "Tenant settings",
            ~p"/app/settings/tenant",
            [Staff.TenantSettingsLive],
            admin: true
          )
        ]
      }
    ]
  end

  defp page(id, label, path, views, opts \\ []) do
    %{
      id: id,
      label: label,
      path: path,
      views: views,
      below: Keyword.get(opts, :below, []),
      admin: Keyword.get(opts, :admin, false)
    }
  end

  @doc """
  The section that holds `view`, or nil for a LiveView outside the navigation.
  """
  def active_section(view) do
    Enum.find(sections(), fn section -> Enum.any?(section.pages, &covers?(&1, view)) end)
  end

  @doc """
  The top-level links `role` may see while `view` is on screen.

  Each link is a map with `:id`, `:label`, `:path`, `:testid` and `:current`.
  `:testid` is the end of the test id; the components put `staff-nav-`,
  `staff-nav-mobile-` or `staff-subnav-` in front. `:current` is the
  `aria-current` value: `"page"` when the link leads to the page on screen,
  `"true"` when that page is elsewhere in the section, and nil for the other
  sections.
  """
  def top_level(role, view) do
    active = active_section(view)

    for section <- sections(), [first | _] <- [visible(section.pages, role)] do
      current =
        cond do
          active == nil or active.id != section.id -> nil
          view in first.views -> "page"
          true -> "true"
        end

      %{
        id: section.id,
        label: section.label,
        path: first.path,
        testid: section.testid,
        current: current
      }
    end
  end

  @doc """
  The second row: the pages of the section that holds `view`, as `role` sees
  them. Empty when the viewer sees fewer than two, since a row with one link
  says nothing the top row has not said.

  Links have the same keys as in `top_level/2`. A detail view marks the page
  it was opened from with `"true"`.
  """
  def second_level(role, view) do
    with %{pages: pages} <- active_section(view),
         [_, _ | _] = pages <- visible(pages, role) do
      for page <- pages do
        current =
          cond do
            view in page.views -> "page"
            view in page.below -> "true"
            true -> nil
          end

        %{
          id: page.id,
          label: page.label,
          path: page.path,
          testid: Atom.to_string(page.id),
          current: current
        }
      end
    else
      _ -> []
    end
  end

  defp covers?(page, view), do: view in page.views or view in page.below

  defp visible(pages, role), do: Enum.filter(pages, &(not &1.admin or role == "admin"))

  @doc """
  The top-level links, for the desktop row and (with `mobile`) the mobile
  menu. Renders the links only; the caller owns the surrounding `<nav>`.
  """
  attr :role, :string, required: true, doc: "the signed-in staff role"
  attr :view, :atom, required: true, doc: "the LiveView on screen"
  attr :mobile, :boolean, default: false

  def top_links(assigns) do
    assigns = assign(assigns, :links, top_level(assigns.role, assigns.view))

    ~H"""
    <.link
      :for={link <- @links}
      navigate={link.path}
      class={top_class(link.current)}
      aria-current={link.current}
      data-testid={
        if @mobile, do: "staff-nav-mobile-#{link.testid}", else: "staff-nav-#{link.testid}"
      }
    >
      {link.label}
    </.link>
    """
  end

  @doc """
  The second row. Renders nothing when `second_level/2` is empty.
  """
  attr :role, :string, required: true, doc: "the signed-in staff role"
  attr :view, :atom, required: true, doc: "the LiveView on screen"

  def second_row(assigns) do
    assigns =
      assigns
      |> assign(:links, second_level(assigns.role, assigns.view))
      |> assign(:section, active_section(assigns.view))

    ~H"""
    <nav
      :if={@links != []}
      class="flex flex-wrap items-center gap-x-0.5 gap-y-1 border-b border-gray-200 bg-white px-4 py-1 dark:border-zinc-700 dark:bg-zinc-800"
      aria-label={@section.label}
      data-testid="staff-subnav"
    >
      <.link
        :for={link <- @links}
        navigate={link.path}
        class={second_class(link.current)}
        aria-current={link.current}
        data-testid={"staff-subnav-#{link.testid}"}
      >
        {link.label}
      </.link>
    </nav>
    """
  end

  # Link labels never break; when the row is too narrow the links wrap whole.
  defp top_class(nil),
    do:
      "whitespace-nowrap text-sm text-gray-600 hover:text-gray-700 dark:text-zinc-300 dark:hover:text-zinc-200 px-2 py-1 rounded-md hover:bg-gray-50 dark:hover:bg-zinc-800"

  defp top_class(_current),
    do:
      "whitespace-nowrap text-sm font-medium text-indigo-600 dark:text-indigo-400 bg-indigo-50 dark:bg-indigo-950 px-2 py-1 rounded-md border-b-2 border-indigo-600 dark:border-indigo-400"

  # One step quieter than the top row: smaller text, and no underline bar.
  @second_base "whitespace-nowrap rounded-md px-2 py-0.5 text-[13px] leading-5 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500"

  defp second_class(nil),
    do: [
      @second_base,
      "text-gray-600 hover:bg-gray-100 hover:text-gray-900 dark:text-zinc-300 dark:hover:bg-zinc-700 dark:hover:text-zinc-100"
    ]

  defp second_class(_current),
    do: [
      @second_base,
      "bg-indigo-50 font-medium text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
    ]
end

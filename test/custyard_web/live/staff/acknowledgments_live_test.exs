defmodule CustyardWeb.Staff.AcknowledgmentsLiveTest do
  defp local_authority(tenant_id, channel),
    do: %Custyard.Acknowledgments.LocalAuthority{tenant_id: tenant_id, channel: channel}

  defp ack_scope(tenant_id) do
    key = {__MODULE__, :scope, tenant_id}

    case Process.get(key) do
      nil ->
        scope = Custyard.Factory.staff_scope(tenant_id)
        Process.put(key, scope)
        scope

      scope ->
        scope
    end
  end

  # Replaces the application's acknowledgment configuration.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Custyard.{Acknowledgments, AuditEvent, Repo}
  alias Custyard.Acknowledgments.Integration
  alias CustyardWeb.Staff.AcknowledgmentsLive

  @password "ui-broker-s3cret"

  setup %{conn: conn} do
    previous = Application.get_env(:custyard, :acknowledgments)
    on_exit(fn -> Application.put_env(:custyard, :acknowledgments, previous) end)
    put_config(enabled: false, url: nil, source: "ots.eu.production")

    # Default factory role is super_admin, which the live_session requires.
    staff = insert_staff_account(role: "admin")
    {:ok, conn: authenticate(conn, staff), staff: staff}
  end

  defp authenticate(conn, staff) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_staff_session(staff)
  end

  defp tenant_id, do: Process.get(:factory_tenant_id)

  defp put_config(overrides) do
    config =
      Keyword.merge(
        [
          queue: "custyard.acknowledgments",
          prefetch: 1,
          source: "ots.eu.production",
          enabled: false
        ],
        overrides
      )

    id = tenant_id()

    case config[:source] do
      nil ->
        Repo.delete_all(from i in Integration, where: i.tenant_id == ^id)

      source ->
        url = config[:url] || "amqp://guest:guest@127.0.0.1:1/ots"
        {:ok, encrypted} = Custyard.Credentials.encrypt(url, "acknowledgments.#{id}.url")

        integration =
          Repo.get_by(Integration, tenant_id: id) ||
            %Integration{}

        integration
        |> Integration.changeset(%{
          tenant_id: id,
          source: source,
          queue: config[:queue],
          enabled: config[:enabled],
          url_ciphertext: encrypted
        })
        |> Repo.insert_or_update!()
    end
  end

  defp binding_audits,
    do: Repo.all(from e in AuditEvent, where: e.event_type == :acknowledgment_binding_created)

  describe "access and navigation" do
    test "agents are turned away", %{conn: conn} do
      admin = insert_staff_account(role: "agent")

      assert {:error, {:redirect, %{to: "/app"}}} =
               live(authenticate(conn, admin), ~p"/app/settings/integrations")
    end

    test "desktop and mobile navigation link to the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/settings/slugs")

      assert html =~ ~s(data-testid="staff-nav-acknowledgments")
      assert html =~ ~s(data-testid="staff-nav-mobile-acknowledgments")
      assert html =~ ~s(href="/app/settings/integrations")
    end
  end

  describe "subscription" do
    test "an unconfigured tenant can set up its subscription", %{conn: conn} do
      put_config(source: nil)
      {:ok, view, html} = live(conn, ~p"/app/settings/integrations")
      assert html =~ "Configure tenant subscription"
      assert html =~ "Broker URL"
      assert view |> element("[data-testid=acknowledgments-status]") |> render() =~ "Disabled"
      refute has_element?(view, "[data-testid=acknowledgments-queues]")
    end

    test "disabled says how it is switched", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      assert view |> element("[data-testid=acknowledgments-status]") |> render() =~ "Disabled"
      assert has_element?(view, "[data-testid=acknowledgments-disabled]")

      assert view |> element("[data-testid=acknowledgments-source]") |> render() =~
               "ots.eu.production"
    end

    test "the broker URL never reaches the page or its assigns", %{conn: conn} do
      # A closed local port fails fast, so the mount's queue count completes.
      put_config(
        enabled: true,
        url: "amqp://custyard:#{@password}@127.0.0.1:1/ots",
        source: "ots.eu.production"
      )

      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")
      html = render_async(view, 10_000)

      assert view |> element("[data-testid=acknowledgments-status]") |> render() =~ "Connecting"

      assert view |> element("[data-testid=acknowledgments-counts-error]") |> render() =~
               "The broker is unreachable"

      refute html =~ @password
      refute html =~ "127.0.0.1"
      refute inspect(:sys.get_state(view.pid).socket.assigns, limit: :infinity) =~ @password
    end
  end

  describe "bindings" do
    test "lists every binding with its organization", %{conn: conn} do
      org = insert_organization(name: "Bound organization")

      {:ok, :created, binding} =
        Acknowledgments.bind(local_authority(tenant_id(), "cli"), "ots.other", "org-77", org.id)

      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      row = view |> element("[data-testid=acknowledgments-binding-#{binding.id}]") |> render()
      assert row =~ "ots.other"
      assert row =~ "org-77"
      assert row =~ "Bound organization"
    end

    test "binding needs a confirmation that names everything and says it is permanent", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization(name: "Acme Support")
      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      view
      |> form("[data-testid=acknowledgments-bind-form]",
        binding: %{source_organization_id: "ots-org-9", organization_id: org.id}
      )
      |> render_submit()

      confirmation =
        view |> element("[data-testid=acknowledgments-bind-confirmation]") |> render()

      assert confirmation =~ "ots.eu.production"
      assert confirmation =~ "ots-org-9"
      assert confirmation =~ "Acme Support"
      assert confirmation =~ "permanent"
      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []

      view |> element("[data-testid=acknowledgments-confirm-bind]") |> render_click()

      assert view |> element("[data-testid=acknowledgments-bind-result]") |> render() =~
               "Bound ots-org-9 to Acme Support"

      assert [%{source: "ots.eu.production", source_organization_id: "ots-org-9"}] =
               Acknowledgments.list_bindings(ack_scope(tenant_id()))

      assert [%{payload: %{"actor" => "staff", "staff_id" => staff_id}}] =
               binding_audits()

      assert staff_id == staff.id
    end

    # organizations is AUTOINCREMENT, so SQLite never gives a deleted
    # organization's id to a new one: a confirmation left open cannot bind
    # an organization created after its review.
    test "confirming after the organization was deleted binds nothing, even once another exists",
         %{conn: conn} do
      org = insert_organization(name: "Reviewed")
      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      view
      |> form("[data-testid=acknowledgments-bind-form]",
        binding: %{source_organization_id: "ots-org-9", organization_id: org.id}
      )
      |> render_submit()

      Repo.delete!(org)
      replacement = insert_organization(name: "Replacement")
      assert replacement.id > org.id

      view |> element("[data-testid=acknowledgments-confirm-bind]") |> render_click()

      assert view |> element("[data-testid=acknowledgments-bind-result]") |> render() =~
               "That organization no longer exists"

      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
      assert binding_audits() == []
    end

    test "cancel leaves nothing bound", %{conn: conn} do
      org = insert_organization()
      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      view
      |> form("[data-testid=acknowledgments-bind-form]",
        binding: %{source_organization_id: "ots-org-9", organization_id: org.id}
      )
      |> render_submit()

      view |> element("[data-testid=acknowledgments-cancel-bind]") |> render_click()

      assert has_element?(view, "[data-testid=acknowledgments-bind-form]")
      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
    end

    test "validation errors and conflicts are shown inline", %{conn: conn} do
      org = insert_organization()
      other = insert_organization(name: "Other")

      {:ok, :created, _} =
        Acknowledgments.bind(
          local_authority(tenant_id(), "cli"),
          "ots.eu.production",
          "taken",
          other.id
        )

      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      view
      |> form("[data-testid=acknowledgments-bind-form]",
        binding: %{source_organization_id: " padded", organization_id: ""}
      )
      |> render_submit()

      errors = view |> element("[data-testid=acknowledgments-bind-errors]") |> render()
      assert errors =~ "nonblank identity"
      assert errors =~ "Choose an existing organization"
      refute has_element?(view, "[data-testid=acknowledgments-bind-confirmation]")

      # An id beyond signed 64 bits is refused before it reaches SQLite.
      render_submit(view, "review_bind", %{
        "binding" => %{
          "source_organization_id" => "big",
          "organization_id" => "9223372036854775808"
        }
      })

      assert view |> element("[data-testid=acknowledgments-bind-errors]") |> render() =~
               "Choose an existing organization"

      view
      |> form("[data-testid=acknowledgments-bind-form]",
        binding: %{source_organization_id: "taken", organization_id: org.id}
      )
      |> render_submit()

      view |> element("[data-testid=acknowledgments-confirm-bind]") |> render_click()

      assert view |> element("[data-testid=acknowledgments-bind-result]") |> render() =~
               "already bound to another organization"

      assert Acknowledgments.get_binding(ack_scope(tenant_id()), "ots.eu.production", "taken").organization_id ==
               other.id

      assert length(binding_audits()) == 1
    end

    test "the form is pinned to the configured source", %{conn: conn} do
      org = insert_organization()
      {:ok, view, _html} = live(conn, ~p"/app/settings/integrations")

      refute has_element?(
               view,
               "[data-testid=acknowledgments-bind-form] [name='binding[source]']"
             )

      render_submit(view, "review_bind", %{
        "binding" => %{
          "source" => "ots.forged",
          "source_organization_id" => "org-1",
          "organization_id" => "#{org.id}"
        }
      })

      view |> element("[data-testid=acknowledgments-confirm-bind]") |> render_click()

      assert [%{source: "ots.eu.production"}] =
               Acknowledgments.list_bindings(ack_scope(tenant_id()))
    end

    test "without a configured source, binding is left to the CLI", %{conn: conn} do
      put_config(enabled: false, url: nil, source: nil)
      org = insert_organization()
      {:ok, view, html} = live(conn, ~p"/app/settings/integrations")

      refute has_element?(view, "[data-testid=acknowledgments-bind-form]")
      assert html =~ "bin/acknowledgments bind"

      render_submit(view, "review_bind", %{
        "binding" => %{"source_organization_id" => "org-1", "organization_id" => "#{org.id}"}
      })

      refute has_element?(view, "[data-testid=acknowledgments-bind-confirmation]")
      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
    end
  end

  # StaffAuth redirects on a role change before a handler runs, so these
  # call the handlers directly to prove each one re-checks for itself.
  describe "event guards" do
    defp socket(staff, assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              flash: %{},
              current_staff: staff,
              current_role: staff.role,
              current_tenant: Custyard.Tenants.get_tenant!(staff.tenant_id),
              current_scope:
                Custyard.Scope.for_staff(
                  staff,
                  Custyard.Tenants.get_tenant!(staff.tenant_id)
                ),
              in_flight: nil,
              confirming_replay: true,
              failure: {:summary, %{readable: true, submission_id: "s-1"}}
            },
            assigns
          )
      }
    end

    defp pending(org),
      do: %{
        source: "ots.eu.production",
        source_organization_id: "org-guarded",
        organization_id: org.id,
        organization_name: org.name
      }

    test "a demoted staff cannot bind, inspect, replay or refresh" do
      org = insert_organization()
      admin = insert_staff_account(role: "agent", tenant_id: org.tenant_id)
      socket = socket(admin, %{pending_bind: pending(org)})

      for event <- ~w(confirm_bind inspect replay refresh confirm_replay) do
        assert {:noreply, returned} = AcknowledgmentsLive.handle_event(event, %{}, socket)
        assert returned.assigns.flash["error"] =~ "Only tenant administrators"
        refute returned.assigns[:in_flight]
      end

      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
    end

    test "events are ignored while an operation runs" do
      org = insert_organization()
      super_admin = insert_staff_account(role: "admin")
      socket = socket(super_admin, %{pending_bind: pending(org), in_flight: :inspect})

      for event <- ~w(confirm_bind inspect replay refresh) do
        assert AcknowledgmentsLive.handle_event(event, %{}, socket) == {:noreply, socket}
      end

      assert AcknowledgmentsLive.handle_event(
               "review_bind",
               %{"binding" => %{"source_organization_id" => "x", "organization_id" => "1"}},
               socket
             ) == {:noreply, socket}

      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
    end

    # Only the page's wait is cancelled; the unlinked replay task may still
    # publish and acknowledge, so the page must not claim it failed.
    test "a replay timeout says the replay may still complete" do
      ref = make_ref()

      socket =
        socket(insert_staff_account(role: "admin"), %{
          in_flight: :replay,
          operation_ref: ref,
          replay_result: nil,
          failure: {:summary, %{readable: true, submission_id: "s-1", body_sha256: "ab"}}
        })

      assert {:noreply, returned} =
               AcknowledgmentsLive.handle_info({:operation_timeout, ref}, socket)

      assert {:error, message} = returned.assigns.replay_result
      assert message =~ "may still complete; inspect again"
      refute message =~ "did not respond"
      assert returned.assigns.failure == nil
      assert returned.assigns.in_flight == nil
    end
  end
end

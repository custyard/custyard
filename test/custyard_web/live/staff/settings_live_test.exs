defmodule CustyardWeb.Staff.SettingsLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{StaffAccount, Repo, Settings}
  alias CustyardWeb.Staff.SettingsLive

  setup %{conn: conn} do
    # Create and authenticate a staff (default role is super_admin)
    {:ok, staff} =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        role: "admin",
        tenant_id: Process.get(:factory_tenant_id),
        email: "settings-test@example.com",
        password: "password123"
      })
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff.id)

    {:ok, conn: conn, staff: staff}
  end

  describe "intake card" do
    test "renders intake config defaults", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/settings/workflow")

      assert html =~ "staff-settings-intake"
      assert html =~ "Unlinked tier score"
      assert html =~ "Slug claim TTL"
    end

    test "super admin can edit and save intake config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/settings/workflow")

      view |> element("[data-testid=staff-settings-edit-intake]") |> render_click()

      view
      |> form("[data-testid=staff-settings-intake-form]", %{
        "intake" => %{"unlinked_tier_score" => "33", "slug_claim_ttl_hours" => "24"}
      })
      |> render_submit()

      assert render(view) =~ "Intake settings updated successfully"

      config = Settings.get_intake_config(Process.get(:factory_tenant_id))
      assert config.unlinked_tier_score == 33
      assert config.slug_claim_ttl_hours == 24
    end

    test "non-super-admin staff cannot save intake config" do
      # The /app/settings/workflow route is mount-gated to super_admin, so this
      # defense-in-depth branch is exercised by invoking the handler directly
      # with a non-super-admin staff in the socket assigns.
      staff = insert_staff_account(role: "agent")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_staff: staff}
      }

      {:noreply, socket} =
        SettingsLive.handle_event(
          "save_intake",
          %{"intake" => %{"unlinked_tier_score" => "99", "slug_claim_ttl_hours" => "1"}},
          socket
        )

      assert socket.assigns.flash["error"] == "Only tenant administrators can modify settings"

      config = Settings.get_intake_config(Process.get(:factory_tenant_id))
      assert config.unlinked_tier_score == 10
      assert config.slug_claim_ttl_hours == 72
    end

    test "rejects out-of-range values with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/settings/workflow")

      view |> element("[data-testid=staff-settings-edit-intake]") |> render_click()

      view
      |> form("[data-testid=staff-settings-intake-form]", %{
        "intake" => %{"unlinked_tier_score" => "500", "slug_claim_ttl_hours" => "24"}
      })
      |> render_submit()

      assert render(view) =~ "Failed to update intake settings"
      assert Settings.get_intake_config(Process.get(:factory_tenant_id)).unlinked_tier_score == 10
    end

    test "rejects non-numeric values with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/settings/workflow")

      view |> element("[data-testid=staff-settings-edit-intake]") |> render_click()

      view
      |> form("[data-testid=staff-settings-intake-form]", %{
        "intake" => %{"unlinked_tier_score" => "lots", "slug_claim_ttl_hours" => "24"}
      })
      |> render_submit()

      assert render(view) =~ "Invalid numeric values for: unlinked_tier_score"
      assert Settings.get_intake_config(Process.get(:factory_tenant_id)).unlinked_tier_score == 10
    end
  end

  describe "score weights" do
    test "shows every weight and accepts an edit", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/app/settings/workflow")

      for key <- ~w(idle state tier urgency velocity neglect) do
        assert html =~ "staff-settings-weight-#{key}"
      end

      view |> element("[phx-click=edit_weights]") |> render_click()

      weights = %{
        "idle" => "0.5",
        "state" => "1.0",
        "tier" => "1.0",
        "urgency" => "1.0",
        "velocity" => "1.0",
        "neglect" => "1.0"
      }

      html =
        view
        |> element("[data-testid=staff-settings-weights-form]")
        |> render_submit(%{"weights" => weights})

      assert html =~ "Weights updated successfully"
      assert Settings.get_weights(Process.get(:factory_tenant_id)).idle == 0.5
    end
  end
end

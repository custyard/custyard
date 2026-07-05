defmodule CustyardWeb.Operator.SettingsLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo, Settings}
  alias CustyardWeb.Operator.SettingsLive

  setup %{conn: conn} do
    # Create and authenticate an operator (default role is super_admin)
    {:ok, operator} =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{
        email: "settings-test@example.com",
        password: "password123"
      })
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)

    {:ok, conn: conn, operator: operator}
  end

  describe "intake card" do
    test "renders intake config defaults", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/operator/settings")

      assert html =~ "operator-settings-intake"
      assert html =~ "Unlinked tier score"
      assert html =~ "Slug claim TTL"
    end

    test "super admin can edit and save intake config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-intake]") |> render_click()

      view
      |> form("[data-testid=operator-settings-intake-form]", %{
        "intake" => %{"unlinked_tier_score" => "33", "slug_claim_ttl_hours" => "24"}
      })
      |> render_submit()

      assert render(view) =~ "Intake settings updated successfully"

      config = Settings.get_intake_config()
      assert config.unlinked_tier_score == 33
      assert config.slug_claim_ttl_hours == 24
    end

    test "non-super-admin operator cannot save intake config" do
      # The /operator/settings route is mount-gated to super_admin, so this
      # defense-in-depth branch is exercised by invoking the handler directly
      # with a non-super-admin operator in the socket assigns.
      operator = insert_operator_account(role: "admin")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_operator: operator}
      }

      {:noreply, socket} =
        SettingsLive.handle_event(
          "save_intake",
          %{"intake" => %{"unlinked_tier_score" => "99", "slug_claim_ttl_hours" => "1"}},
          socket
        )

      assert socket.assigns.flash["error"] == "Only super admins can modify settings"

      config = Settings.get_intake_config()
      assert config.unlinked_tier_score == 10
      assert config.slug_claim_ttl_hours == 72
    end

    test "rejects out-of-range values with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-intake]") |> render_click()

      view
      |> form("[data-testid=operator-settings-intake-form]", %{
        "intake" => %{"unlinked_tier_score" => "500", "slug_claim_ttl_hours" => "24"}
      })
      |> render_submit()

      assert render(view) =~ "Failed to update intake settings"
      assert Settings.get_intake_config().unlinked_tier_score == 10
    end

    test "rejects non-numeric values with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-intake]") |> render_click()

      view
      |> form("[data-testid=operator-settings-intake-form]", %{
        "intake" => %{"unlinked_tier_score" => "lots", "slug_claim_ttl_hours" => "24"}
      })
      |> render_submit()

      assert render(view) =~ "Invalid numeric values for: unlinked_tier_score"
      assert Settings.get_intake_config().unlinked_tier_score == 10
    end
  end
end

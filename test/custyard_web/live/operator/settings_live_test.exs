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

  describe "branding card" do
    test "renders branding defaults", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/operator/settings")

      assert html =~ "operator-settings-branding"
      assert html =~ "Logo URL"
      assert html =~ "Primary color"
    end

    test "super admin can edit and save branding", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{
          "name" => "Acme Support",
          "logo_url" => "/uploads/logos/acme.png",
          "primary_color" => "#1a2b3c"
        }
      })
      |> render_submit()

      assert render(view) =~ "Branding updated successfully"

      branding = Settings.get_branding()
      assert branding.name == "Acme Support"
      assert branding.logo_url == "/uploads/logos/acme.png"
      assert branding.primary_color == "#1a2b3c"
    end

    test "blank fields clear branding values", %{conn: conn} do
      {:ok, _} = Settings.update_branding(%{name: "Acme", primary_color: "#112233"})

      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "Acme", "logo_url" => "", "primary_color" => ""}
      })
      |> render_submit()

      branding = Settings.get_branding()
      assert branding.name == "Acme"
      assert branding.primary_color == nil
    end

    test "whitespace-only fields clear rather than store blanks", %{conn: conn} do
      {:ok, _} = Settings.update_branding(%{name: "Acme", primary_color: "#112233"})

      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "   ", "logo_url" => "", "primary_color" => "#112233"}
      })
      |> render_submit()

      # A whitespace name is treated as blank: cleared to nil, never stored,
      # so consumers' nil -> "Custyard" fallback still applies.
      branding = Settings.get_branding()
      assert branding.name == nil
      assert branding.primary_color == "#112233"
    end

    test "rejects a traversal logo path with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{
          "name" => "",
          "logo_url" => "/uploads/../secrets",
          "primary_color" => ""
        }
      })
      |> render_submit()

      assert render(view) =~ "Failed to update branding"
      assert Settings.get_branding().logo_url == nil
    end

    test "rejects a malformed color with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "", "logo_url" => "", "primary_color" => "blue"}
      })
      |> render_submit()

      assert render(view) =~ "Failed to update branding"
      assert Settings.get_branding().primary_color == nil
    end

    test "non-super-admin operator cannot save branding" do
      # Same defense-in-depth precedent as the intake card: the route is
      # mount-gated, so the double-gate branch is exercised directly.
      operator = insert_operator_account(role: "admin")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_operator: operator}
      }

      {:noreply, socket} =
        SettingsLive.handle_event(
          "save_branding",
          %{"branding" => %{"name" => "Hijacked"}},
          socket
        )

      assert socket.assigns.flash["error"] == "Only super admins can modify settings"
      assert Settings.get_branding().name == nil
    end
  end
end

defmodule CustyardWeb.Operator.SettingsLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo, Settings}
  alias CustyardWeb.Operator.SettingsLive

  # Minimal valid PNG header bytes - enough for upload plumbing tests
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

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
      assert html =~ "Logo"
      assert html =~ "Primary color"
    end

    test "super admin can edit and save branding", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{
          "name" => "Acme Support",
          "primary_color" => "#1a2b3c"
        }
      })
      |> render_submit()

      assert render(view) =~ "Branding updated successfully"

      branding = Settings.get_branding()
      assert branding.name == "Acme Support"
      assert branding.logo_url == nil
      assert branding.primary_color == "#1a2b3c"
    end

    test "blank fields clear branding values", %{conn: conn} do
      {:ok, _} = Settings.update_branding(%{name: "Acme", primary_color: "#112233"})

      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "Acme", "primary_color" => ""}
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
        "branding" => %{"name" => "   ", "primary_color" => "#112233"}
      })
      |> render_submit()

      # A whitespace name is treated as blank: cleared to nil, never stored,
      # so consumers' nil -> "Custyard" fallback still applies.
      branding = Settings.get_branding()
      assert branding.name == nil
      assert branding.primary_color == "#112233"
    end

    test "ignores an injected logo_url param (logo comes only from uploads)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      # There is no logo_url input anymore; a crafted payload must not reach
      # Settings.update_branding as a logo path.
      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "Acme", "primary_color" => ""}
      })
      |> render_submit(%{"branding" => %{"logo_url" => "/uploads/../secrets"}})

      assert render(view) =~ "Branding updated successfully"
      assert Settings.get_branding().logo_url == nil
    end

    test "rejects a malformed color with a flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "", "primary_color" => "blue"}
      })
      |> render_submit()

      assert render(view) =~ "Failed to update branding"
      assert Settings.get_branding().primary_color == nil
    end

    test "color picker change updates the visible hex value", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> element("[data-testid=operator-settings-branding-form]")
      |> render_change(%{
        "_target" => ["branding", "primary_color_picker"],
        "branding" => %{"primary_color_picker" => "#aabbcc"}
      })

      assert has_element?(
               view,
               "[data-testid=operator-settings-branding-color-input][value='#aabbcc']"
             )
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

  describe "branding logo upload" do
    test "uploading a logo saves the file and persists its /uploads/ path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      logo =
        file_input(view, "[data-testid=operator-settings-branding-form]", :logo, [
          %{name: "logo.png", content: @png, type: "image/png"}
        ])

      render_upload(logo, "logo.png")

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "Acme", "primary_color" => ""}
      })
      |> render_submit()

      assert render(view) =~ "Branding updated successfully"

      branding = Settings.get_branding()
      assert branding.logo_url =~ ~r{\A/uploads/logos/[0-9a-f\-]+\.png\z}

      path = logo_disk_path(branding.logo_url)
      on_exit(fn -> File.rm(path) end)
      assert File.exists?(path)

      # Read-mode display shows a thumbnail of the current logo
      assert has_element?(view, "[data-testid=operator-settings-branding-logo-thumb]")
    end

    test "uploading a replacement logo deletes the old file", %{conn: conn} do
      {old_url, old_path} = seed_logo_file!()
      {:ok, _} = Settings.update_branding(%{logo_url: old_url})

      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      logo =
        file_input(view, "[data-testid=operator-settings-branding-form]", :logo, [
          %{name: "new-logo.png", content: @png, type: "image/png"}
        ])

      render_upload(logo, "new-logo.png")

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "", "primary_color" => ""}
      })
      |> render_submit()

      assert render(view) =~ "Branding updated successfully"

      branding = Settings.get_branding()
      assert branding.logo_url != old_url

      new_path = logo_disk_path(branding.logo_url)
      on_exit(fn -> File.rm(new_path) end)

      assert File.exists?(new_path)
      refute File.exists?(old_path)
    end

    test "remove logo clears the stored path and deletes the file", %{conn: conn} do
      {url, path} = seed_logo_file!()
      {:ok, _} = Settings.update_branding(%{name: "Acme", logo_url: url})

      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "Acme", "primary_color" => "", "remove_logo" => "true"}
      })
      |> render_submit()

      assert render(view) =~ "Branding updated successfully"
      assert Settings.get_branding().logo_url == nil
      refute File.exists?(path)
    end

    test "saving without a new upload keeps the existing logo", %{conn: conn} do
      {url, path} = seed_logo_file!()
      {:ok, _} = Settings.update_branding(%{logo_url: url})

      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "Acme", "primary_color" => ""}
      })
      |> render_submit()

      assert render(view) =~ "Branding updated successfully"
      assert Settings.get_branding().logo_url == url
      assert File.exists?(path)
    end

    test "a failed save does not persist the uploaded logo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/settings")

      view |> element("[data-testid=operator-settings-edit-branding]") |> render_click()

      logo =
        file_input(view, "[data-testid=operator-settings-branding-form]", :logo, [
          %{name: "logo.png", content: @png, type: "image/png"}
        ])

      render_upload(logo, "logo.png")

      view
      |> form("[data-testid=operator-settings-branding-form]", %{
        "branding" => %{"name" => "", "primary_color" => "nope"}
      })
      |> render_submit()

      assert render(view) =~ "Failed to update branding"
      assert Settings.get_branding().logo_url == nil
    end
  end

  defp logo_disk_path("/uploads/logos/" <> filename) do
    upload_dir = Application.get_env(:custyard, :upload_dir)
    Path.join([upload_dir, "logos", filename])
  end

  # Writes a fake pre-existing logo file into the upload dir and registers
  # cleanup. Returns {public_url, disk_path}.
  defp seed_logo_file! do
    filename = "#{Ecto.UUID.generate()}.png"
    upload_dir = Application.get_env(:custyard, :upload_dir)
    dir = Path.join(upload_dir, "logos")
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)
    {"/uploads/logos/#{filename}", path}
  end
end

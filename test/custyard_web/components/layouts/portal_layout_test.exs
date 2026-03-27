defmodule CustyardWeb.Layouts.PortalLayoutTest do
  @moduledoc """
  Tests for portal layout branding features.

  Verifies that organization-specific branding (logo, colors, name) renders
  correctly in the portal layout, and that appropriate fallbacks are used
  when branding fields are not set.
  """
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  describe "organization logo" do
    test "renders logo when organization has logo_url", %{conn: conn} do
      org = insert_organization(logo_url: "/uploads/logos/acme-logo.png")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ ~s(data-testid="portal-nav-logo")
      assert html =~ ~s(src="/uploads/logos/acme-logo.png")
      assert html =~ ~s(alt="#{org.name} logo")
    end

    test "does not render logo element when organization has no logo_url", %{conn: conn} do
      org = insert_organization(logo_url: nil)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      refute html =~ ~s(data-testid="portal-nav-logo")
    end
  end

  describe "primary color styling" do
    test "applies primary_color to organization name", %{conn: conn} do
      org = insert_organization(name: "Acme Corp", primary_color: "#ff5500")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      # The org name should have inline style with the primary color
      assert html =~ "Acme Corp"
      assert html =~ ~s(color: #ff5500)
    end

    test "applies primary_color to New Request button", %{conn: conn} do
      org = insert_organization(primary_color: "#00aa33")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ ~s(data-testid="portal-nav-new-request")
      assert html =~ ~s(background-color: #00aa33)
    end

    test "uses default indigo color when no primary_color set", %{conn: conn} do
      org = insert_organization(primary_color: nil)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      # Should use the default indigo color for the button
      assert html =~ ~s(data-testid="portal-nav-new-request")
      assert html =~ ~s(background-color: #4f46e5)
    end

    test "does not apply inline color style to org name when no primary_color", %{conn: conn} do
      org = insert_organization(name: "Plain Org", primary_color: nil)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      # The org name should appear but without a color style in that span
      assert html =~ "Plain Org"
      # The span with org name should not have style="color: ..."
      # We can verify this by checking the name appears without inline color
      refute html =~ ~r/Plain Org.*style="color:/s
    end
  end

  describe "organization name" do
    test "displays organization name when set", %{conn: conn} do
      org = insert_organization(name: "Custom Company Name")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ "Custom Company Name"
    end

    # Note: The template has a fallback to "Support Portal" when @current_org.name is nil,
    # but the database schema has a NOT NULL constraint on organizations.name, so this
    # code path cannot be reached in practice. The fallback exists as defensive coding
    # and for cases where current_org might not be set (though that shouldn't happen
    # with proper PortalAuth middleware).
  end

  describe "data-testid attributes" do
    test "portal layout has expected data-testid attributes", %{conn: conn} do
      org = insert_organization(logo_url: "/uploads/test.png", primary_color: "#123456")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      # Layout structure
      assert html =~ ~s(data-testid="portal-layout")
      assert html =~ ~s(data-testid="portal-layout-nav")
      assert html =~ ~s(data-testid="portal-layout-content")

      # Navigation elements
      assert html =~ ~s(data-testid="portal-nav-logo")
      assert html =~ ~s(data-testid="portal-nav-requests")
      assert html =~ ~s(data-testid="portal-nav-projects")
      assert html =~ ~s(data-testid="portal-nav-new-request")
    end
  end
end

defmodule CustyardWeb.Portal.HelpersTest do
  use Custyard.DataCase, async: true

  alias CustyardWeb.Portal.Helpers

  import Custyard.Factory

  describe "get_organization/2" do
    test "returns organization when org_token param is provided" do
      org = insert_organization(token: "test-token-abc")

      result = Helpers.get_organization(%{"org_token" => "test-token-abc"}, %{assigns: %{}})

      assert result.id == org.id
      assert result.token == "test-token-abc"
    end

    test "raises when org_token does not exist" do
      socket = %{assigns: %{}}

      assert_raise Ecto.NoResultsError, fn ->
        Helpers.get_organization(%{"org_token" => "nonexistent"}, socket)
      end
    end

    test "returns organization from socket assigns for custom domain" do
      org = insert_organization()
      socket = %{assigns: %{organization: org}}

      result = Helpers.get_organization(%{}, socket)

      assert result.id == org.id
    end

    test "raises when custom domain but no organization assigned" do
      socket = %{assigns: %{}}

      assert_raise RuntimeError, "Organization not found for custom domain", fn ->
        Helpers.get_organization(%{}, socket)
      end
    end
  end

  describe "custom_domain?/1" do
    test "returns true when custom_domain_request is set" do
      socket = %{assigns: %{custom_domain_request: true}}

      assert Helpers.custom_domain?(socket) == true
    end

    test "returns false when custom_domain_request is false" do
      socket = %{assigns: %{custom_domain_request: false}}

      assert Helpers.custom_domain?(socket) == false
    end

    test "returns false when custom_domain_request is not set" do
      socket = %{assigns: %{}}

      assert Helpers.custom_domain?(socket) == false
    end
  end

  describe "assign_portal_path/1" do
    test "assigns token-based paths for standard routes" do
      org = insert_organization(token: "org-token-123")
      socket = build_socket(%{org: org, custom_domain_request: false})

      result = Helpers.assign_portal_path(socket)

      assert result.assigns.portal_path == "/p/org-token-123"
      assert result.assigns.portal_home_path == "/p/org-token-123"
      assert result.assigns.is_custom_domain == false
    end

    test "assigns empty base path for custom domains" do
      org = insert_organization()
      socket = build_socket(%{org: org, custom_domain_request: true})

      result = Helpers.assign_portal_path(socket)

      assert result.assigns.portal_path == ""
      assert result.assigns.portal_home_path == "/"
      assert result.assigns.is_custom_domain == true
    end

    test "defaults to standard routes when custom_domain_request not set" do
      org = insert_organization(token: "default-token")
      socket = build_socket(%{org: org})

      result = Helpers.assign_portal_path(socket)

      assert result.assigns.portal_path == "/p/default-token"
      assert result.assigns.is_custom_domain == false
    end
  end

  describe "portal_path/2" do
    test "generates path with token prefix for standard routes using socket" do
      socket = build_socket(%{portal_path: "/p/my-token"})

      assert Helpers.portal_path(socket, "/request/123") == "/p/my-token/request/123"
      assert Helpers.portal_path(socket, "/new") == "/p/my-token/new"
    end

    test "generates root-relative path for custom domains using socket" do
      socket = build_socket(%{portal_path: ""})

      assert Helpers.portal_path(socket, "/request/123") == "/request/123"
      assert Helpers.portal_path(socket, "/new") == "/new"
    end

    test "works with assigns map instead of socket" do
      assigns = %{portal_path: "/p/test-token"}

      assert Helpers.portal_path(assigns, "/request/456") == "/p/test-token/request/456"
    end

    test "works with empty portal_path in assigns map" do
      assigns = %{portal_path: ""}

      assert Helpers.portal_path(assigns, "/") == "/"
    end
  end

  # Helper to build a mock socket struct that Phoenix.Component.assign/3 can work with
  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end
end

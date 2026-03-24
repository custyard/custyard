defmodule CustyardWeb.Plugs.CustomDomainTest do
  use Custyard.DataCase, async: true

  import Plug.Test

  alias CustyardWeb.Plugs.CustomDomain

  import Custyard.Factory

  describe "call/2" do
    test "passes through requests to app host without modification" do
      conn = conn(:get, "/some/path") |> Map.put(:host, "localhost")

      result = CustomDomain.call(conn, [])

      assert result.host == "localhost"
      assert result.request_path == "/some/path"
      refute Map.has_key?(result.assigns, :organization)
      refute Map.has_key?(result.assigns, :custom_domain_request)
    end

    test "passes through requests to 127.0.0.1" do
      conn = conn(:get, "/path") |> Map.put(:host, "127.0.0.1")

      result = CustomDomain.call(conn, [])

      assert result.request_path == "/path"
      refute Map.has_key?(result.assigns, :organization)
    end

    test "passes through unknown custom domains without modification" do
      conn = conn(:get, "/") |> Map.put(:host, "unknown.example.com")

      result = CustomDomain.call(conn, [])

      assert result.request_path == "/"
      refute Map.has_key?(result.assigns, :organization)
    end

    test "rewrites root path for known custom domain" do
      org = insert_organization(custom_domain: "support.acme.com", token: "acme-token")
      conn = conn(:get, "/") |> Map.put(:host, "support.acme.com")

      result = CustomDomain.call(conn, [])

      assert result.request_path == "/p/acme-token/"
      assert result.path_info == ["p", "acme-token"]
      assert result.assigns.organization.id == org.id
      assert result.assigns.custom_domain_request == true
      assert result.private[:custyard_custom_domain] == true
    end

    test "rewrites subpath for known custom domain" do
      org = insert_organization(custom_domain: "help.example.org", token: "example-org")
      conn = conn(:get, "/request/123") |> Map.put(:host, "help.example.org")

      result = CustomDomain.call(conn, [])

      assert result.request_path == "/p/example-org/request/123"
      assert result.path_info == ["p", "example-org", "request", "123"]
      assert result.assigns.organization.id == org.id
    end

    test "rewrites /new path for custom domain" do
      insert_organization(custom_domain: "portal.test.io", token: "test-io-token")
      conn = conn(:get, "/new") |> Map.put(:host, "portal.test.io")

      result = CustomDomain.call(conn, [])

      assert result.request_path == "/p/test-io-token/new"
      assert result.path_info == ["p", "test-io-token", "new"]
    end

    test "does not double-prefix paths already starting with /p/" do
      insert_organization(custom_domain: "support.acme.com", token: "acme-token")
      conn = conn(:get, "/p/other-token/request/1") |> Map.put(:host, "support.acme.com")

      result = CustomDomain.call(conn, [])

      # Should not become /p/acme-token/p/other-token/request/1
      assert result.request_path == "/p/other-token/request/1"
      assert result.path_info == ["p", "other-token", "request", "1"]
      # Still assigns the org for the custom domain
      assert result.assigns.custom_domain_request == true
    end
  end

  describe "custom_domain?/1" do
    test "returns true when custom domain flag is set" do
      conn = %Plug.Conn{private: %{custyard_custom_domain: true}}

      assert CustomDomain.custom_domain?(conn) == true
    end

    test "returns false when flag is not set" do
      conn = %Plug.Conn{private: %{}}

      assert CustomDomain.custom_domain?(conn) == false
    end

    test "returns false when flag is explicitly false" do
      conn = %Plug.Conn{private: %{custyard_custom_domain: false}}

      assert CustomDomain.custom_domain?(conn) == false
    end
  end

  describe "init/1" do
    test "passes through options unchanged" do
      assert CustomDomain.init([]) == []
      assert CustomDomain.init(foo: :bar) == [foo: :bar]
    end
  end
end

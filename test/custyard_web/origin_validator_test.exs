defmodule CustyardWeb.OriginValidatorTest do
  use Custyard.DataCase, async: true

  alias CustyardWeb.OriginValidator

  import Custyard.Factory

  describe "check_origin/1" do
    test "accepts localhost in dev/test environment" do
      # Application env is :test by default in tests
      assert OriginValidator.check_origin("http://localhost:4000")
      assert OriginValidator.check_origin("https://localhost")
      assert OriginValidator.check_origin("http://localhost")
    end

    test "accepts custom_domain from organization in database" do
      insert_organization(custom_domain: "support.acme.com")

      assert OriginValidator.check_origin("https://support.acme.com")
      assert OriginValidator.check_origin("http://support.acme.com")
      assert OriginValidator.check_origin("https://support.acme.com:443")
    end

    test "rejects unknown origin" do
      # No organization with this domain
      refute OriginValidator.check_origin("https://unknown-domain.com")
      refute OriginValidator.check_origin("https://attacker.evil.com")
    end

    test "case-insensitive host matching for custom domains" do
      insert_organization(custom_domain: "Support.Acme.Com")

      # Should match regardless of case
      assert OriginValidator.check_origin("https://support.acme.com")
      assert OriginValidator.check_origin("https://SUPPORT.ACME.COM")
      assert OriginValidator.check_origin("https://SuPpOrT.AcMe.CoM")
    end

    test "case-insensitive localhost matching" do
      assert OriginValidator.check_origin("http://LOCALHOST:4000")
      assert OriginValidator.check_origin("http://LocalHost")
    end

    test "rejects nil origin" do
      refute OriginValidator.check_origin(nil)
    end

    test "rejects non-string origin" do
      refute OriginValidator.check_origin(123)
      refute OriginValidator.check_origin(%{})
      refute OriginValidator.check_origin([])
    end

    test "rejects malformed URL" do
      refute OriginValidator.check_origin("not-a-url")
      refute OriginValidator.check_origin("")
    end

    test "handles origin with port number" do
      insert_organization(custom_domain: "portal.widgets.io")

      assert OriginValidator.check_origin("https://portal.widgets.io:443")
      assert OriginValidator.check_origin("http://portal.widgets.io:8080")
    end

    test "accepts PHX_HOST when configured" do
      # Get the configured host from endpoint config
      primary_host =
        Application.get_env(:custyard, CustyardWeb.Endpoint)
        |> get_in([:url, :host])

      # Skip if no host is configured
      if primary_host do
        assert OriginValidator.check_origin("https://#{primary_host}")
      end
    end
  end

  describe "list_valid_origins/0" do
    test "includes localhost in dev/test" do
      origins = OriginValidator.list_valid_origins()
      assert "//localhost" in origins
    end

    test "includes custom domains from database" do
      insert_organization(custom_domain: "portal1.example.com")
      insert_organization(custom_domain: "portal2.example.com")

      origins = OriginValidator.list_valid_origins()

      assert "//portal1.example.com" in origins
      assert "//portal2.example.com" in origins
    end

    test "excludes organizations without custom_domain" do
      insert_organization(domain: "acme.example.com", custom_domain: nil)

      origins = OriginValidator.list_valid_origins()

      refute "//acme.example.com" in origins
    end

    test "excludes organizations with empty custom_domain" do
      insert_organization(custom_domain: "")

      origins = OriginValidator.list_valid_origins()

      # Empty strings should be excluded
      refute "//" in origins
    end
  end

  describe "check_origin?/2 (Phoenix MFA interface)" do
    # Phoenix's socket config uses MFA callback with arity 2:
    # websocket: [check_origin: {CustyardWeb.OriginValidator, :check_origin?, []}]
    # Phoenix passes %URI{} struct and opts to this function.

    test "accepts localhost URI in dev/test environment" do
      uri = %URI{host: "localhost", scheme: "http", port: 4000}
      assert OriginValidator.check_origin?(uri, [])
    end

    test "accepts localhost with arity-1 fallback" do
      uri = %URI{host: "localhost", scheme: "http", port: 4000}
      assert OriginValidator.check_origin?(uri)
    end

    test "accepts custom domain from organization" do
      insert_organization(custom_domain: "support.widgets.io")

      uri = %URI{host: "support.widgets.io", scheme: "https", port: 443}
      assert OriginValidator.check_origin?(uri, [])
    end

    test "rejects unknown host" do
      uri = %URI{host: "unknown.evil.com", scheme: "https", port: 443}
      refute OriginValidator.check_origin?(uri, [])
    end

    test "case-insensitive host matching" do
      insert_organization(custom_domain: "Portal.Example.Com")

      uri_lower = %URI{host: "portal.example.com", scheme: "https"}
      uri_upper = %URI{host: "PORTAL.EXAMPLE.COM", scheme: "https"}
      uri_mixed = %URI{host: "PoRtAl.ExAmPlE.cOm", scheme: "https"}

      assert OriginValidator.check_origin?(uri_lower, [])
      assert OriginValidator.check_origin?(uri_upper, [])
      assert OriginValidator.check_origin?(uri_mixed, [])
    end

    test "rejects URI with nil host" do
      uri = %URI{host: nil, scheme: "https"}
      refute OriginValidator.check_origin?(uri, [])
    end

    test "rejects non-URI struct" do
      refute OriginValidator.check_origin?("not-a-uri", [])
      refute OriginValidator.check_origin?(%{host: "localhost"}, [])
      refute OriginValidator.check_origin?(nil, [])
    end

    test "opts parameter is accepted but unused" do
      # Phoenix may pass various opts - verify they don't break the function
      uri = %URI{host: "localhost", scheme: "http"}

      assert OriginValidator.check_origin?(uri, transport: :websocket)
      assert OriginValidator.check_origin?(uri, some_option: "value")
      assert OriginValidator.check_origin?(uri, [])
    end
  end

  describe "edge cases" do
    test "handles multiple organizations with custom domains" do
      insert_organization(custom_domain: "portal-a.example.com")
      insert_organization(custom_domain: "portal-b.example.com")
      insert_organization(custom_domain: "portal-c.example.com")

      assert OriginValidator.check_origin("https://portal-a.example.com")
      assert OriginValidator.check_origin("https://portal-b.example.com")
      assert OriginValidator.check_origin("https://portal-c.example.com")
    end

    test "handles origin with path (only host should be checked)" do
      insert_organization(custom_domain: "portal.example.com")

      # The URI.parse extracts the host, path should not affect validation
      assert OriginValidator.check_origin("https://portal.example.com/some/path")
    end

    test "handles origin with query string" do
      insert_organization(custom_domain: "portal.example.com")

      assert OriginValidator.check_origin("https://portal.example.com?foo=bar")
    end

    test "subdomain does not match parent domain" do
      insert_organization(custom_domain: "example.com")

      # Subdomain should NOT match - strict domain matching
      refute OriginValidator.check_origin("https://sub.example.com")
    end
  end
end

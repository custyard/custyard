defmodule Custyard.InboundRoutesCustomDomainTest do
  # async: false - stages Lettermint mock results through application env.
  use Custyard.DataCase, async: false

  alias Custyard.{Factory, InboundChannel, InboundRoute, InboundRoutes}

  setup do
    on_exit(fn -> Application.delete_env(:custyard, :lettermint_mock_inbound_verification) end)
    org = Factory.insert_organization()
    {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})
    %{org: org, route: route}
  end

  defp with_failing_client(_context) do
    original = Application.get_env(:custyard, :lettermint)
    Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)
    on_exit(fn -> Application.put_env(:custyard, :lettermint, original) end)
    :ok
  end

  describe "InboundRoute custom domain rules" do
    test "accepts exact domains and left-hand wildcards, lowercased" do
      changeset =
        InboundRoute.changeset(%InboundRoute{organization_id: 1}, %{
          lettermint_custom_domain: " Help.Acme.COM "
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :lettermint_custom_domain) == "help.acme.com"

      wildcard =
        InboundRoute.changeset(%InboundRoute{organization_id: 1}, %{
          lettermint_custom_domain: "*.m.acme.com"
        })

      assert wildcard.valid?
    end

    test "rejects malformed domains, inner wildcards and Lettermint domains" do
      for domain <- [
            "not a domain",
            "help.*.acme.com",
            "acme",
            "x.lettermint.app",
            "lettermint.mx"
          ] do
        changeset =
          InboundRoute.changeset(%InboundRoute{organization_id: 1}, %{
            lettermint_custom_domain: domain
          })

        refute changeset.valid?, "expected #{domain} to be rejected"
        assert changeset.errors[:lettermint_custom_domain]
      end
    end

    test "custom_domain_covers?/2: exact match, strict subdomains of a wildcard" do
      exact = %InboundRoute{lettermint_custom_domain: "help.acme.com"}
      assert InboundRoute.custom_domain_covers?(exact, "help.acme.com")
      assert InboundRoute.custom_domain_covers?(exact, "HELP.acme.com")
      refute InboundRoute.custom_domain_covers?(exact, "eu.help.acme.com")

      wildcard = %InboundRoute{lettermint_custom_domain: "*.m.acme.com"}
      assert InboundRoute.custom_domain_covers?(wildcard, "eu.m.acme.com")
      assert InboundRoute.custom_domain_covers?(wildcard, "a.eu.m.acme.com")
      refute InboundRoute.custom_domain_covers?(wildcard, "m.acme.com")
      refute InboundRoute.custom_domain_covers?(wildcard, "evilm.acme.com")

      refute InboundRoute.custom_domain_covers?(%InboundRoute{}, "help.acme.com")
    end

    test "forward_domain/1 ignores a verified custom domain" do
      route = %InboundRoute{
        lettermint_route_domain: "ab12cd34ef.lettermint.app",
        lettermint_custom_domain: "help.acme.com",
        lettermint_custom_domain_verified_at: ~U[2026-10-20 12:00:00Z]
      }

      assert InboundRoute.forward_domain(route) == "ab12cd34ef.lettermint.app"
      assert InboundRoute.ingress_domain(route) == "help.acme.com"
      assert InboundRoute.custom_domain_verified?(route)

      refute InboundRoute.custom_domain_verified?(%{
               route
               | lettermint_custom_domain_verified_at: nil
             })
    end
  end

  describe "set_custom_domain/2" do
    test "stores the domain with verification reset", %{route: route} do
      assert {:ok, route} = InboundRoutes.set_custom_domain(route, "Help.Acme.com")
      assert route.lettermint_custom_domain == "help.acme.com"
      assert route.lettermint_custom_domain_verified_at == nil
    end

    test "validates before calling Lettermint", %{route: route} = context do
      with_failing_client(context)

      assert {:error, %Ecto.Changeset{}} =
               InboundRoutes.set_custom_domain(route, "x.lettermint.app")
    end

    test "returns the Lettermint error and leaves the route unchanged",
         %{route: route} = context do
      with_failing_client(context)

      assert {:error, {:api_error, 503, _}} =
               InboundRoutes.set_custom_domain(route, "help.acme.com")

      assert Repo.reload(route).lettermint_custom_domain == nil
    end

    test "is a no-op for the current domain", %{route: route} = context do
      {:ok, route} = InboundRoutes.set_custom_domain(route, "help.acme.com")
      with_failing_client(context)

      assert {:ok, ^route} = InboundRoutes.set_custom_domain(route, "help.acme.com")
    end

    test "refuses to move a domain a direct-MX channel depends on", %{org: org, route: route} do
      {:ok, route} = InboundRoutes.set_custom_domain(route, "help.acme.com")

      %InboundChannel{}
      |> InboundChannel.changeset(%{
        public_address: "support@help.acme.com",
        ingress_kind: :mx,
        inbound_route_id: route.id,
        organization_id: org.id
      })
      |> Repo.insert!()

      assert {:error, :domain_in_use} = InboundRoutes.set_custom_domain(route, "other.acme.com")
    end

    test "rejects non-Lettermint routes", %{org: org} do
      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general,
          source: :email
        })

      assert {:error, :not_a_lettermint_route} =
               InboundRoutes.set_custom_domain(route, "help.acme.com")
    end
  end

  describe "verify_custom_domain/1" do
    test "stamps verification on success and returns the MX details", %{route: route} do
      {:ok, route} = InboundRoutes.set_custom_domain(route, "help.acme.com")

      assert {:ok, route, %{"verified" => true, "expected_mx_records" => ["10 lettermint.mx"]}} =
               InboundRoutes.verify_custom_domain(route)

      assert %DateTime{} = route.lettermint_custom_domain_verified_at
      assert InboundRoute.custom_domain_verified?(route)
    end

    test "a failed check leaves the route unverified", %{route: route} do
      {:ok, route} = InboundRoutes.set_custom_domain(route, "help.acme.com")

      Application.put_env(
        :custyard,
        :lettermint_mock_inbound_verification,
        {:ok, %{"verified" => false, "message" => "MX not found", "found_mx_records" => []}}
      )

      assert {:ok, route, %{"verified" => false}} = InboundRoutes.verify_custom_domain(route)
      assert route.lettermint_custom_domain_verified_at == nil
    end

    test "a failed re-check keeps an earlier verification", %{route: route} do
      {:ok, route} = InboundRoutes.set_custom_domain(route, "help.acme.com")
      {:ok, route, _} = InboundRoutes.verify_custom_domain(route)
      verified_at = route.lettermint_custom_domain_verified_at

      Application.put_env(
        :custyard,
        :lettermint_mock_inbound_verification,
        {:ok, %{"verified" => false, "message" => "DNS timeout"}}
      )

      assert {:ok, route, _} = InboundRoutes.verify_custom_domain(route)
      assert route.lettermint_custom_domain_verified_at == verified_at
    end

    test "needs a custom domain", %{route: route} do
      assert {:error, :no_custom_domain} = InboundRoutes.verify_custom_domain(route)
    end
  end
end

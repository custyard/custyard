defmodule Custyard.InboundChannelTest do
  use Custyard.DataCase, async: true

  alias Custyard.InboundChannel

  @token_regex ~r/\A[0-9abcdefghjkmnpqrstvwxyz]{20}\z/
  @now ~U[2026-10-20 12:00:00Z]

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        public_address: "support@acme.example.com",
        ingress_kind: :forward,
        inbound_route_id: 1,
        organization_id: 1
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}) do
    InboundChannel.changeset(%InboundChannel{}, valid_attrs(overrides))
  end

  defp channel(attrs) do
    struct!(
      %InboundChannel{
        public_address: "support@acme.example.com",
        ingress_local: "support",
        ingress_token: "0123456789abcdefghjk"
      },
      attrs
    )
  end

  describe "changeset/2" do
    test "is valid with a public address, route and organization" do
      cs = changeset()

      assert cs.valid?, inspect(cs.errors)
      assert get_change(cs, :public_address) == "support@acme.example.com"
      assert get_change(cs, :ingress_local) == "support"
      assert get_change(cs, :ingress_token) =~ @token_regex
    end

    test "requires a public address" do
      assert %{public_address: ["can't be blank"]} = errors_on(changeset(%{public_address: nil}))
      assert %{public_address: ["can't be blank"]} = errors_on(changeset(%{public_address: "  "}))
    end

    test "requires a route and tenant while allowing a shared tenant channel" do
      errors =
        errors_on(changeset(%{inbound_route_id: nil, organization_id: nil, tenant_id: nil}))

      assert %{inbound_route_id: ["can't be blank"], tenant_id: ["can't be blank"]} = errors
    end

    test "rejects a malformed public address" do
      for bad <- ["support", "support@", "@acme.example.com", "support@localhost", "a b@x.io"] do
        assert %{public_address: ["must be a valid email address"]} =
                 errors_on(changeset(%{public_address: bad})),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "lowercases and trims the public address" do
      cs = changeset(%{public_address: "  Support@ACME.Example.COM "})
      assert get_change(cs, :public_address) == "support@acme.example.com"
    end

    test "trims the display name and blanks it to nil" do
      assert get_change(changeset(%{display_name: "  Acme Support "}), :display_name) ==
               "Acme Support"

      assert is_nil(get_change(changeset(%{display_name: "   "}), :display_name))
    end

    test "normalizes an optional sending domain and rejects addresses, URLs and invalid hostnames" do
      cs = changeset(%{sending_domain: "  MAIL.Acme.Example.COM  "})
      assert cs.valid?
      assert get_change(cs, :sending_domain) == "mail.acme.example.com"

      for bad <- [
            "https://mail.example.com",
            "help@mail.example.com",
            "*.example.com",
            "mail..example.com",
            "-mail.example.com",
            "mail.example.com\r\nBcc: x@y.com",
            String.duplicate("a", 64) <> ".example.com",
            Enum.map_join([63, 63, 63, 61], ".", &String.duplicate("a", &1))
          ] do
        assert %{sending_domain: [_ | _]} = errors_on(changeset(%{sending_domain: bad}))
      end
    end

    test "changing or clearing the sending domain resets its verification" do
      existing =
        channel(%{
          inbound_route_id: 1,
          sending_domain: "mail.acme.example.com",
          sending_domain_status: "verified",
          sending_domain_checked_at: @now
        })

      for domain <- ["other.acme.example.com", ""] do
        cs = InboundChannel.changeset(existing, %{sending_domain: domain})
        assert cs.valid?
        assert fetch_change(cs, :sending_domain_status) == {:ok, nil}
        assert fetch_change(cs, :sending_domain_checked_at) == {:ok, nil}
      end
    end

    test "bounds quiet_after_hours to 1..720" do
      assert changeset(%{quiet_after_hours: 1}).valid?
      assert changeset(%{quiet_after_hours: 720}).valid?

      assert %{quiet_after_hours: [_]} = errors_on(changeset(%{quiet_after_hours: 0}))
      assert %{quiet_after_hours: [_]} = errors_on(changeset(%{quiet_after_hours: 721}))
    end

    test "never casts the ingress token from attrs" do
      cs = changeset(%{ingress_token: "attacker-chosen-token"})
      assert get_change(cs, :ingress_token) =~ @token_regex
    end

    test "keeps an existing token on update" do
      existing = channel(%{})
      cs = InboundChannel.changeset(existing, %{display_name: "Sales"})

      refute Map.has_key?(cs.changes, :ingress_token)
      refute Map.has_key?(cs.changes, :ingress_local)
    end
  end

  describe "ingress_local derivation" do
    test "mirrors the lowercased local part" do
      cs = changeset(%{public_address: "Support.Team_1-x@acme.example.com"})
      assert get_change(cs, :ingress_local) == "support.team_1-x"
    end

    test "replaces characters outside the conservative set" do
      cs = changeset(%{public_address: "hello&world!@acme.example.com"})
      assert cs.valid?, inspect(cs.errors)
      assert get_change(cs, :ingress_local) == "hello-world-"
    end

    test "strips every leading dot, hyphen and underscore" do
      cs = changeset(%{public_address: "-._-.support@acme.example.com"})
      assert cs.valid?, inspect(cs.errors)
      assert get_change(cs, :ingress_local) == "support"
    end

    test "falls back to mail when nothing usable remains" do
      cs = changeset(%{public_address: ".-.@acme.example.com"})
      assert cs.valid?, inspect(cs.errors)
      assert get_change(cs, :ingress_local) == "mail"
    end

    test "caps the local part so local+token fits a 64-octet local part" do
      long = String.duplicate("a", 60)
      cs = changeset(%{public_address: "#{long}@acme.example.com"})
      assert cs.valid?, inspect(cs.errors)

      local = get_change(cs, :ingress_local)
      token = get_change(cs, :ingress_token)

      assert String.length(local) == 43
      assert String.length("#{local}+#{token}") == 64
    end
  end

  describe "generate_token/0" do
    test "is 20 lowercase Crockford base32 characters" do
      token = InboundChannel.generate_token()

      assert String.length(token) == InboundChannel.token_length()
      assert token =~ @token_regex
      refute token =~ ~r/[ilou]/
    end

    test "is unique per generation" do
      tokens = for _ <- 1..200, do: InboundChannel.generate_token()
      assert length(Enum.uniq(tokens)) == 200
    end
  end

  describe "state_changeset/3" do
    test "allows every transition the state machine lists" do
      for {from, targets} <- InboundChannel.transitions(), to <- targets do
        cs = InboundChannel.state_changeset(channel(%{state: from}), to)
        assert cs.valid?, "#{from} -> #{to} should be allowed"
        assert get_change(cs, :state) == to
        assert InboundChannel.valid_transition?(from, to)
      end
    end

    test "rejects transitions the state machine does not list" do
      disallowed = [
        {:draft, :active},
        {:draft, :awaiting_first_message},
        {:draft, :paused},
        {:active, :pending_verification},
        {:active, :awaiting_first_message},
        {:awaiting_first_message, :pending_verification},
        {:revoked, :active},
        {:revoked, :paused},
        {:revoked, :draft}
      ]

      for {from, to} <- disallowed do
        cs = InboundChannel.state_changeset(channel(%{state: from}), to)
        refute cs.valid?, "#{from} -> #{to} should be rejected"
        assert %{state: ["cannot transition from #{from} to #{to}"]} == errors_on(cs)
        refute InboundChannel.valid_transition?(from, to)
      end
    end

    test "revoked is terminal" do
      assert InboundChannel.transitions()[:revoked] == []
    end

    test "staying in the same state is a no-op, not an error" do
      cs = InboundChannel.state_changeset(channel(%{state: :active}), :active)
      assert cs.valid?
      assert cs.changes == %{}
    end

    test "carries the transition timestamps" do
      cs =
        InboundChannel.state_changeset(channel(%{state: :active}), :paused, %{paused_at: @now})

      assert get_change(cs, :paused_at) == @now
    end
  end

  describe "address helpers" do
    test "ingress_address/2 joins local, token and domain" do
      assert InboundChannel.ingress_address(channel(%{}), "r1.lettermint.app") ==
               "support+0123456789abcdefghjk@r1.lettermint.app"
    end

    test "ingress_address/2 is nil without a domain" do
      assert is_nil(InboundChannel.ingress_address(channel(%{}), nil))
      assert is_nil(InboundChannel.ingress_address(channel(%{}), ""))
    end

    test "masked_ingress_address/2 keeps four characters at each end of the token" do
      assert InboundChannel.masked_ingress_address(channel(%{}), "r1.lettermint.app") ==
               "support+0123…ghjk@r1.lettermint.app"

      assert is_nil(InboundChannel.masked_ingress_address(channel(%{}), nil))
    end

    test "public_domain/1 is the part after the @" do
      assert InboundChannel.public_domain(channel(%{})) == "acme.example.com"
      assert is_nil(InboundChannel.public_domain(%InboundChannel{}))
    end
  end

  describe "previous_token_valid?/2" do
    test "is false without a previous token or expiry" do
      refute InboundChannel.previous_token_valid?(channel(%{}), @now)

      refute InboundChannel.previous_token_valid?(
               channel(%{previous_ingress_token: "0123456789abcdefghjk"}),
               @now
             )
    end

    test "is true until the grace period ends" do
      token = "0123456789abcdefghjk"

      assert InboundChannel.previous_token_valid?(
               channel(%{
                 previous_ingress_token: token,
                 previous_token_expires_at: DateTime.add(@now, 1, :second)
               }),
               @now
             )

      refute InboundChannel.previous_token_valid?(
               channel(%{previous_ingress_token: token, previous_token_expires_at: @now}),
               @now
             )

      refute InboundChannel.previous_token_valid?(
               channel(%{
                 previous_ingress_token: token,
                 previous_token_expires_at: DateTime.add(@now, -1, :second)
               }),
               @now
             )
    end
  end

  describe "verification" do
    test "verification_valid?/2 follows the expiry" do
      refute InboundChannel.verification_valid?(channel(%{}), @now)

      assert InboundChannel.verification_valid?(
               channel(%{verification_expires_at: DateTime.add(@now, 60, :second)}),
               @now
             )

      refute InboundChannel.verification_valid?(
               channel(%{verification_expires_at: DateTime.add(@now, -60, :second)}),
               @now
             )
    end

    test "verification_changeset/4 stores code and link with a 24h expiry" do
      cs =
        InboundChannel.verification_changeset(
          channel(%{}),
          %{code: " 123456 ", link: "https://mail.google.com/confirm?x=1"},
          @now
        )

      assert cs.valid?, inspect(cs.errors)
      assert get_change(cs, :verification_code) == "123456"
      assert get_change(cs, :verification_link) == "https://mail.google.com/confirm?x=1"
      assert get_change(cs, :verification_captured_at) == @now
      assert get_change(cs, :verification_expires_at) == DateTime.add(@now, 24 * 3600, :second)
    end

    test "verification_changeset/4 rejects non-https links and blanks empty values" do
      cs =
        InboundChannel.verification_changeset(
          channel(%{}),
          %{code: "", link: "http://mail.google.com/confirm"},
          @now
        )

      assert %{verification_link: ["must be an https link"]} = errors_on(cs)
      assert is_nil(get_field(cs, :verification_code))
    end

    test "clear_verification_changeset/1 blanks every verification field" do
      cs =
        InboundChannel.clear_verification_changeset(
          channel(%{
            verification_code: "1",
            verification_link: "https://x",
            verification_captured_at: @now,
            verification_expires_at: @now
          })
        )

      assert cs.changes == %{
               verification_code: nil,
               verification_link: nil,
               verification_captured_at: nil,
               verification_expires_at: nil
             }
    end
  end

  describe "receiving?/1" do
    test "is true for the states that create conversations" do
      for state <- [:pending_verification, :awaiting_first_message, :active] do
        assert InboundChannel.receiving?(channel(%{state: state}))
      end

      for state <- [:draft, :paused, :revoked] do
        refute InboundChannel.receiving?(channel(%{state: state}))
      end
    end
  end

  describe "sending_domain_changeset/3" do
    test "accepts every known status" do
      for status <- InboundChannel.sending_domain_statuses() do
        cs = InboundChannel.sending_domain_changeset(channel(%{}), status, @now)
        assert get_change(cs, :sending_domain_status) == status
        assert get_change(cs, :sending_domain_checked_at) == @now
      end
    end

    test "refuses an unknown status" do
      assert_raise FunctionClauseError, fn ->
        InboundChannel.sending_domain_changeset(channel(%{}), "whatever", @now)
      end
    end
  end
end

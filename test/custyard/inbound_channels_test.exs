defmodule Custyard.InboundChannelsTest do
  # async: false — sending-domain tests mutate the Lettermint client config.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.{AuditEvent, InboundChannel, InboundChannelRejection, InboundChannels, Repo}

  setup do
    previous = Application.get_env(:custyard, :lettermint)

    Application.put_env(
      :custyard,
      :lettermint,
      Keyword.put(previous || [], :client, Custyard.Lettermint.MockClient)
    )

    on_exit(fn -> Application.put_env(:custyard, :lettermint, previous) end)
    :ok
  end

  @token_a "0123456789abcdefghjk"
  @token_b "kjhgfedcba9876543210"
  @token_regex ~r/\A[0-9abcdefghjkmnpqrstvwxyz]{20}\z/

  defp insert_route(overrides \\ []) do
    overrides =
      Keyword.put_new_lazy(overrides, :organization_id, fn -> insert_organization().id end)

    id = System.unique_integer([:positive])

    insert_inbound_route(
      Keyword.merge(
        [
          route_type: :general,
          source: :lettermint,
          lettermint_route_id: "lm_route_#{id}",
          lettermint_route_domain: "r#{id}.lettermint.app"
        ],
        overrides
      )
    )
  end

  defp audit_events(event_type) do
    from(a in AuditEvent, where: a.event_type == ^event_type, order_by: a.id) |> Repo.all()
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  defp reload(%InboundChannel{id: id}), do: InboundChannels.get_channel!(id)

  defp ingress(channel, token \\ nil) do
    domain = channel.inbound_route.lettermint_route_domain
    "#{channel.ingress_local}+#{token || channel.ingress_token}@#{domain}"
  end

  defp backdate!(%InboundChannel{} = channel, changes) do
    channel |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  describe "operator mutation boundaries" do
    test "confirmation consumes verification captured after the channel was loaded" do
      channel = insert_inbound_channel(state: :pending_verification)
      operator = insert_operator_account(role: "admin")
      {:ok, _} = InboundChannels.capture_verification(channel, %{code: "new-code"})

      assert {:ok, confirmed} =
               InboundChannels.confirm_verification(channel, operator: operator)

      assert is_nil(confirmed.verification_code)
      assert is_nil(Repo.reload!(channel).verification_captured_at)
    end

    test "revocation retires a previous token rotated after the channel was loaded" do
      channel = insert_inbound_channel(state: :active)
      operator = insert_operator_account(role: "admin")
      {:ok, _} = InboundChannels.rotate_token(channel, operator: operator)

      assert {:ok, revoked} = InboundChannels.revoke(channel, operator: operator)
      assert is_nil(revoked.previous_ingress_token)
      assert is_nil(Repo.reload!(channel).previous_token_expires_at)
    end

    test "a rotated session cannot create, edit, transition, rotate or delete a channel" do
      route = insert_route()
      operator = insert_operator_account(role: "admin", tenant_id: route.tenant_id)

      {:ok, channel} =
        InboundChannels.create_channel(route, %{public_address: "support@acme.example.com"})

      Repo.update!(
        Ecto.Changeset.change(operator,
          session_claim: Custyard.OperatorAccount.generate_session_claim()
        )
      )

      assert {:error, :unauthorized} =
               InboundChannels.create_channel(route, %{public_address: "other@acme.example.com"},
                 operator: operator
               )

      assert {:error, :unauthorized} =
               InboundChannels.update_channel(channel, %{archive_copy: true}, operator: operator)

      for action <- [:confirm_verification, :pause, :revoke, :rotate_token, :delete_channel] do
        assert {:error, :unauthorized} =
                 apply(InboundChannels, action, [channel, [operator: operator]])
      end

      assert Repo.reload!(channel).state == :pending_verification
      refute Repo.reload!(channel).archive_copy
      assert length(InboundChannels.list_for_route(route.id)) == 1
    end

    test "a tenant administrator cannot edit another tenant's channel" do
      route = insert_route()

      tenant =
        Repo.insert!(%Custyard.Tenant{
          name: "Other channel tenant",
          slug: "other-channel-#{System.unique_integer([:positive])}"
        })

      operator = insert_operator_account(role: "admin", tenant_id: tenant.id)

      {:ok, channel} =
        InboundChannels.create_channel(route, %{public_address: "support@acme.example.com"})

      assert {:error, :unauthorized} =
               InboundChannels.update_channel(channel, %{archive_copy: true}, operator: operator)

      refute Repo.reload!(channel).archive_copy
    end
  end

  describe "delayed check boundaries" do
    setup do
      previous = Application.get_env(:custyard, :lettermint)
      fixture = Application.get_env(:custyard, :email_setup_test_provider)
      Application.put_env(:custyard, :lettermint, client: Custyard.EmailSetupTestProvider)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, previous)

        if fixture,
          do: Application.put_env(:custyard, :email_setup_test_provider, fixture),
          else: Application.delete_env(:custyard, :email_setup_test_provider)
      end)

      :ok
    end

    test "a revoked administrator cannot persist a completed domain check" do
      route = insert_route()
      operator = insert_operator_account(role: "admin", tenant_id: route.tenant_id)

      {:ok, channel} =
        InboundChannels.create_channel(route, %{public_address: "support@acme.example.com"})

      Application.put_env(:custyard, :email_setup_test_provider, %{
        domains: fn ->
          operator |> Custyard.OperatorAccount.role_changeset(%{role: "agent"}) |> Repo.update!()
          {:ok, [%{"domain" => "acme.example.com", "status" => "verified"}]}
        end
      })

      assert {:error, :unauthorized} =
               InboundChannels.check_sending_domain(channel, operator: operator)

      assert is_nil(Repo.reload!(channel).sending_domain_status)
    end

    test "suspension during a domain lookup prevents persisting its result" do
      route = insert_route()
      operator = insert_operator_account(role: "admin", tenant_id: route.tenant_id)
      channel = insert_inbound_channel(inbound_route_id: route.id)

      Application.put_env(:custyard, :email_setup_test_provider, %{
        domains: fn ->
          Repo.get!(Custyard.Tenant, route.tenant_id)
          |> Ecto.Changeset.change(status: "suspended")
          |> Repo.update!()

          {:ok, [%{"domain" => InboundChannel.sending_domain(channel), "status" => "verified"}]}
        end
      })

      assert {:error, :unauthorized} =
               InboundChannels.check_sending_domain(channel, operator: operator)

      assert is_nil(Repo.reload!(channel).sending_domain_status)

      assert {:error, :unauthorized} =
               InboundChannels.update_channel(channel, %{archive_copy: true}, operator: operator)
    end

    test "a completed domain check cannot certify changed channel configuration" do
      route = insert_route()
      operator = insert_operator_account(role: "admin")

      {:ok, channel} =
        InboundChannels.create_channel(route, %{public_address: "support@acme.example.com"})

      Application.put_env(:custyard, :email_setup_test_provider, %{
        domains: fn ->
          {:ok, _} = InboundChannels.update_channel(channel, %{reply_from: :ingress_address})
          {:ok, [%{"domain" => "acme.example.com", "status" => "verified"}]}
        end
      })

      assert {:error, :stale_configuration} =
               InboundChannels.check_sending_domain(channel, operator: operator)

      assert is_nil(Repo.reload!(channel).sending_domain_status)
    end

    test "a completed domain check cannot certify a newly selected sending domain" do
      route = insert_route()
      operator = insert_operator_account(role: "admin")
      channel = insert_inbound_channel(inbound_route_id: route.id)

      Application.put_env(:custyard, :email_setup_test_provider, %{
        domains: fn ->
          {:ok, _} =
            InboundChannels.update_channel(channel, %{sending_domain: "mail.acme.example.com"})

          {:ok, [%{"domain" => InboundChannel.public_domain(channel), "status" => "verified"}]}
        end
      })

      assert {:error, :stale_configuration} =
               InboundChannels.check_sending_domain(channel, operator: operator)

      assert is_nil(Repo.reload!(channel).sending_domain_status)
    end

    test "a late MX check cannot reactivate a paused channel or stamp its route" do
      route = insert_route(lettermint_custom_domain: "mx.example.com")

      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          tenant_id: route.tenant_id,
          public_address: "support@mx.example.com",
          ingress_kind: :mx,
          state: :pending_verification
        )

      operator = insert_operator_account(role: "admin")

      Application.put_env(:custyard, :email_setup_test_provider, %{
        mx: fn ->
          {:ok, _} = InboundChannels.pause(channel)
          {:ok, %{"verified" => true}}
        end
      })

      assert {:error, :stale_configuration} =
               InboundChannels.check_mx(channel, operator: operator)

      assert Repo.reload!(channel).state == :paused
      assert is_nil(Repo.reload!(route).lettermint_custom_domain_verified_at)
    end
  end

  describe "create_channel/3" do
    test "starts pending_verification with route scope, preloads and an audit event" do
      route = insert_route()
      operator = insert_operator_account(role: "admin")

      assert {:ok, channel} =
               InboundChannels.create_channel(
                 route,
                 %{public_address: " Support@Acme.Example.com ", display_name: " Acme "},
                 operator: operator
               )

      assert channel.state == :pending_verification
      assert channel.public_address == "support@acme.example.com"
      assert channel.display_name == "Acme"
      assert channel.ingress_local == "support"
      assert channel.ingress_token =~ @token_regex
      assert channel.inbound_route_id == route.id
      assert channel.tenant_id == route.tenant_id
      assert Ecto.assoc_loaded?(channel.inbound_route)
      assert Ecto.assoc_loaded?(channel.default_project)

      assert [event] = audit_events(:channel_created)
      assert event.tenant_id == route.tenant_id
      assert event.source == "inbound_channels"

      assert event.payload["channel_id"] == channel.id
      assert event.payload["operator_id"] == operator.id
      assert event.payload["public_address"] == "support@acme.example.com"
    end

    test "stores a customer project as an optional channel hint" do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      route = insert_route(organization_id: org.id, route_type: :project, project_id: project.id)

      assert {:ok, channel} =
               InboundChannels.create_channel(route, %{
                 public_address: "proj@acme.example.com",
                 default_project_id: project.id
               })

      assert channel.default_project_id == project.id
    end

    test "accepts string keys" do
      route = insert_route()

      assert {:ok, %InboundChannel{}} =
               InboundChannels.create_channel(route, %{"public_address" => "a@acme.example.com"})
    end

    test "enforces one channel per (route, public address)" do
      route = insert_route()
      attrs = %{public_address: "support@acme.example.com"}

      assert {:ok, _} = InboundChannels.create_channel(route, attrs)
      assert {:error, changeset} = InboundChannels.create_channel(route, attrs)
      assert %{public_address: ["is already a channel on this route"]} = errors_on(changeset)

      other_route = insert_route(tenant_id: route.tenant_id)
      assert {:ok, _} = InboundChannels.create_channel(other_route, attrs)
    end

    test "returns the invalid changeset without an audit event" do
      route = insert_route()

      assert {:error, changeset} =
               InboundChannels.create_channel(route, %{public_address: "nope"})

      assert %{public_address: [_]} = errors_on(changeset)
      assert audit_events(:channel_created) == []
    end
  end

  describe "update_channel/3" do
    test "updates editable attributes and ignores the public address" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")

      assert {:ok, updated} =
               InboundChannels.update_channel(channel, %{
                 public_address: "other@acme.example.com",
                 display_name: "Acme Support",
                 quiet_after_hours: 24,
                 reply_from: :ingress_address,
                 provider: :proton
               })

      assert updated.public_address == "support@acme.example.com"
      assert updated.ingress_local == "support"
      assert updated.ingress_token == channel.ingress_token
      assert updated.display_name == "Acme Support"
      assert updated.quiet_after_hours == 24
      assert updated.reply_from == :ingress_address
      assert updated.provider == :proton

      assert [event] = audit_events(:channel_updated)

      assert Enum.sort(event.payload["changed"]) ==
               ~w(display_name provider quiet_after_hours reply_from)
    end

    test "validates the quiet window" do
      channel = insert_inbound_channel()

      assert {:error, changeset} =
               InboundChannels.update_channel(channel, %{quiet_after_hours: 0})

      assert %{quiet_after_hours: [_]} = errors_on(changeset)
    end
  end

  describe "verification" do
    test "capture_verification/3 stores code and link with a 24h expiry" do
      channel = insert_inbound_channel()

      assert {:ok, updated} =
               InboundChannels.capture_verification(channel, %{
                 code: "654321",
                 link: "https://mail.google.com/confirm?x=1"
               })

      assert updated.verification_code == "654321"
      assert updated.verification_link == "https://mail.google.com/confirm?x=1"
      assert %DateTime{} = updated.verification_captured_at

      assert DateTime.diff(updated.verification_expires_at, updated.verification_captured_at) ==
               24 * 3600

      assert InboundChannel.verification_valid?(updated, DateTime.utc_now())

      assert [event] = audit_events(:channel_verification_captured)
      assert event.payload["has_code"] == true
      assert event.payload["has_link"] == true
      refute Map.has_key?(event.payload, "code")
    end

    test "capture_verification/3 rejects a non-https link" do
      channel = insert_inbound_channel()

      assert {:error, changeset} =
               InboundChannels.capture_verification(channel, %{link: "http://evil.example/x"})

      assert %{verification_link: ["must be an https link"]} = errors_on(changeset)
    end

    test "confirm_verification/2 consumes the capture and moves to awaiting_first_message" do
      channel = insert_inbound_channel()
      {:ok, channel} = InboundChannels.capture_verification(channel, %{code: "1", link: nil})

      assert {:ok, confirmed} = InboundChannels.confirm_verification(channel)
      assert confirmed.state == :awaiting_first_message
      assert %DateTime{} = confirmed.verified_at
      assert is_nil(confirmed.verification_code)
      assert is_nil(confirmed.verification_expires_at)
      assert is_nil(confirmed.verification_captured_at)

      assert [event] = audit_events(:channel_state_changed)
      assert event.payload["from"] == "pending_verification"
      assert event.payload["to"] == "awaiting_first_message"
    end

    test "confirm_verification/2 does not regress a channel a delivery just activated" do
      stale = insert_inbound_channel(state: :pending_verification)
      {:ok, active} = InboundChannels.mark_received(stale)
      assert active.state == :active

      assert {:error, %Ecto.Changeset{} = changeset} = InboundChannels.confirm_verification(stale)
      assert Keyword.has_key?(changeset.errors, :state)
      assert Repo.reload!(stale).state == :active
    end

    test "confirm_verification/2 consumes a late capture without regressing the channel" do
      channel = insert_inbound_channel(state: :awaiting_first_message)

      {:ok, channel} =
        InboundChannels.capture_verification(channel, %{
          code: nil,
          link: "https://account.proton.me/email-forwarding/accept#confirmation-token"
        })

      assert {:ok, confirmed} = InboundChannels.confirm_verification(channel)
      assert confirmed.state == :awaiting_first_message
      assert confirmed.verified_at == channel.verified_at
      assert is_nil(confirmed.verification_link)
      assert is_nil(Repo.reload!(channel).verification_captured_at)
    end

    test "confirm_verification/2 rejects states without a pending or late capture" do
      for state <- [:awaiting_first_message, :active, :paused, :revoked, :draft] do
        channel = insert_inbound_channel(state: state)

        assert {:error, %Ecto.Changeset{} = changeset} =
                 InboundChannels.confirm_verification(channel)

        assert %{state: [_]} = errors_on(changeset)
      end
    end
  end

  describe "pause/2 and resume/2" do
    test "pause stamps paused_at from any receiving state" do
      for state <- [:pending_verification, :awaiting_first_message, :active] do
        channel = insert_inbound_channel(state: state)
        assert {:ok, paused} = InboundChannels.pause(channel)
        assert paused.state == :paused
        assert %DateTime{} = paused.paused_at
      end
    end

    test "resume returns to pending_verification when never verified" do
      channel = insert_inbound_channel(state: :paused)
      assert {:ok, resumed} = InboundChannels.resume(channel)
      assert resumed.state == :pending_verification
      assert is_nil(resumed.paused_at)
    end

    test "resume returns to awaiting_first_message once verified" do
      channel = insert_inbound_channel(state: :paused, verified_at: hours_ago(1))
      assert {:ok, resumed} = InboundChannels.resume(channel)
      assert resumed.state == :awaiting_first_message
    end

    test "resume returns to active once mail has been received" do
      channel =
        insert_inbound_channel(
          state: :paused,
          verified_at: hours_ago(2),
          last_received_at: hours_ago(1)
        )

      assert {:ok, resumed} = InboundChannels.resume(channel)
      assert resumed.state == :active
    end

    test "resume refuses a channel that is not paused" do
      channel = insert_inbound_channel(state: :active)
      assert {:error, changeset} = InboundChannels.resume(channel)
      assert %{state: ["cannot resume a channel in state active"]} = errors_on(changeset)
    end
  end

  describe "revoke/2" do
    test "retires the previous token and is terminal" do
      channel = insert_inbound_channel(state: :active)
      {:ok, rotated} = InboundChannels.rotate_token(channel)
      assert rotated.previous_ingress_token == channel.ingress_token

      assert {:ok, revoked} = InboundChannels.revoke(rotated)
      assert revoked.state == :revoked
      assert %DateTime{} = revoked.revoked_at
      assert is_nil(revoked.previous_ingress_token)
      assert is_nil(revoked.previous_token_expires_at)

      assert {:error, _} = InboundChannels.pause(revoked)
      assert {:error, _} = InboundChannels.resume(revoked)
      assert {:error, _} = InboundChannels.confirm_verification(revoked)
      assert {:error, _} = InboundChannels.rotate_token(revoked)
      assert reload(revoked).state == :revoked
    end

    test "cannot revoke a draft twice but can revoke from draft" do
      channel = insert_inbound_channel(state: :draft)
      assert {:ok, revoked} = InboundChannels.revoke(channel)
      assert revoked.state == :revoked
    end
  end

  describe "rotate_token/2" do
    test "issues a new token and keeps the old one for the grace period" do
      channel = insert_inbound_channel(state: :active, ingress_token: @token_a)

      assert {:ok, rotated} = InboundChannels.rotate_token(channel, grace_hours: 2)
      assert rotated.ingress_token =~ @token_regex
      assert rotated.ingress_token != @token_a
      assert rotated.previous_ingress_token == @token_a

      assert_in_delta DateTime.diff(rotated.previous_token_expires_at, DateTime.utc_now()),
                      2 * 3600,
                      5

      route = rotated.inbound_route
      assert {:ok, %{id: id}} = InboundChannels.resolve_for_delivery(route, ingress(rotated))
      assert id == channel.id

      assert {:ok, %{id: ^id}} =
               InboundChannels.resolve_for_delivery(route, ingress(rotated, @token_a))

      assert [event] = audit_events(:channel_token_rotated)
      assert event.payload["grace_hours"] == 2
      refute inspect(event.payload) =~ @token_a
      refute inspect(event.payload) =~ rotated.ingress_token
    end

    test "defaults to a seven day grace period" do
      channel = insert_inbound_channel(state: :active)
      assert {:ok, rotated} = InboundChannels.rotate_token(channel)

      assert_in_delta DateTime.diff(rotated.previous_token_expires_at, DateTime.utc_now()),
                      7 * 24 * 3600,
                      5
    end

    test "refuses on a revoked channel" do
      channel = insert_inbound_channel(state: :revoked)
      assert {:error, changeset} = InboundChannels.rotate_token(channel)
      assert %{state: ["cannot rotate_token a channel in state revoked"]} = errors_on(changeset)
    end
  end

  describe "record_reveal/2 and delete_channel/2" do
    test "record_reveal writes an audit event without the token" do
      channel = insert_inbound_channel()
      operator = insert_operator_account(role: "admin")

      assert :ok = InboundChannels.record_reveal(channel, operator: operator)

      assert [event] = audit_events(:channel_token_revealed)
      assert event.payload["channel_id"] == channel.id
      assert event.payload["operator_id"] == operator.id
      refute inspect(event.payload) =~ channel.ingress_token
    end

    test "delete_channel removes the row and audits" do
      channel = insert_inbound_channel()
      InboundChannels.subscribe_tenant(channel.tenant_id)

      assert {:ok, _} = InboundChannels.delete_channel(channel)
      assert is_nil(InboundChannels.get_channel(channel.id))
      assert [_] = audit_events(:channel_deleted)
      assert_receive {:channel_updated, id}
      assert id == channel.id
    end
  end

  describe "reads and address helpers" do
    test "tenant lists and scoped reads cannot expose another tenant's channel" do
      mine = insert_inbound_channel()
      theirs = insert_inbound_channel(tenant_id: insert_tenant().id)
      staff = insert_operator_account(role: "admin", tenant_id: mine.tenant_id)
      scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(mine.tenant_id))
      assert [%{id: id}] = InboundChannels.list_for_tenant(mine.tenant_id)
      assert id == mine.id
      assert %InboundChannel{} = InboundChannels.get(scope, mine.id)
      assert is_nil(InboundChannels.get(scope, theirs.id))
    end

    test "ingress_address/1 and masked_ingress_address/1 use the route domain" do
      channel = insert_inbound_channel(ingress_token: @token_a)
      domain = channel.inbound_route.lettermint_route_domain

      assert InboundChannels.ingress_address(channel) ==
               "#{channel.ingress_local}+#{@token_a}@#{domain}"

      assert InboundChannels.masked_ingress_address(channel) ==
               "#{channel.ingress_local}+0123…ghjk@#{domain}"

      # Also resolves the route when it is not preloaded.
      bare = %{channel | inbound_route: %Ecto.Association.NotLoaded{}}
      assert InboundChannels.ingress_address(bare) == InboundChannels.ingress_address(channel)
    end

    test "ingress_address/1 is nil when the route has no domain" do
      route = insert_inbound_route(source: :lettermint)
      channel = insert_inbound_channel(inbound_route_id: route.id)

      assert is_nil(InboundChannels.ingress_address(channel))
      assert is_nil(InboundChannels.masked_ingress_address(channel))
    end

    test "from_address/1 and from_name/1 follow reply_from and display_name" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")
      assert InboundChannels.from_address(channel) == "support@acme.example.com"
      assert is_nil(InboundChannels.from_name(channel))

      {:ok, fallback} =
        InboundChannels.update_channel(channel, %{
          reply_from: :ingress_address,
          display_name: "Acme"
        })

      assert InboundChannels.from_address(fallback) == InboundChannels.ingress_address(fallback)
      assert InboundChannels.from_name(fallback) == "Acme"
    end
  end

  describe "resolve_for_delivery/2" do
    test "requires an explicit channel on every receiving route" do
      route = insert_route()

      assert InboundChannels.resolve_for_delivery(route, "anything@x.lettermint.app") ==
               {:error, :no_channel}
    end

    test "matches the current token" do
      channel = insert_inbound_channel(state: :active, ingress_token: @token_a)

      _other =
        insert_inbound_channel(
          inbound_route_id: channel.inbound_route_id,
          ingress_token: @token_b
        )

      assert {:ok, %InboundChannel{id: id}} =
               InboundChannels.resolve_for_delivery(channel.inbound_route, ingress(channel))

      assert id == channel.id
    end

    test "is case-insensitive on the recipient" do
      channel = insert_inbound_channel(state: :active, ingress_token: @token_a)
      recipient = channel |> ingress() |> String.upcase()

      assert {:ok, %{id: id}} =
               InboundChannels.resolve_for_delivery(channel.inbound_route, recipient)

      assert id == channel.id
    end

    test "matches a previous token inside the grace period only" do
      channel = insert_inbound_channel(state: :active, ingress_token: @token_a)
      {:ok, rotated} = InboundChannels.rotate_token(channel, grace_hours: 1)
      route = rotated.inbound_route

      assert {:ok, _} = InboundChannels.resolve_for_delivery(route, ingress(rotated, @token_a))

      backdate!(rotated, previous_token_expires_at: hours_ago(1))

      assert InboundChannels.resolve_for_delivery(route, ingress(rotated, @token_a)) ==
               {:error, :no_channel}

      assert {:ok, _} = InboundChannels.resolve_for_delivery(route, ingress(rotated))
    end

    test "is {:error, :no_channel} for unknown tokens, missing plus tags and bad recipients" do
      channel = insert_inbound_channel(state: :active, ingress_token: @token_a)
      route = channel.inbound_route
      domain = route.lettermint_route_domain

      assert InboundChannels.resolve_for_delivery(route, ingress(channel, @token_b)) ==
               {:error, :no_channel}

      assert InboundChannels.resolve_for_delivery(route, "#{channel.ingress_local}@#{domain}") ==
               {:error, :no_channel}

      assert InboundChannels.resolve_for_delivery(route, "+#{@token_a}@#{domain}") ==
               {:error, :no_channel}

      assert InboundChannels.resolve_for_delivery(route, "support+@#{domain}") ==
               {:error, :no_channel}

      assert InboundChannels.resolve_for_delivery(route, nil) == {:error, :no_channel}
      assert InboundChannels.resolve_for_delivery(route, "") == {:error, :no_channel}
    end

    test "does not match a token belonging to a channel on another route" do
      channel = insert_inbound_channel(state: :active, ingress_token: @token_a)
      other = insert_inbound_channel(state: :active, ingress_token: @token_b)

      assert InboundChannels.resolve_for_delivery(channel.inbound_route, ingress(other)) ==
               {:error, :no_channel}
    end

    test "reports paused and revoked channels, and ignores drafts" do
      paused = insert_inbound_channel(state: :paused, ingress_token: @token_a)
      revoked = insert_inbound_channel(state: :revoked, ingress_token: @token_b)
      draft = insert_inbound_channel(state: :draft)

      assert {:paused, %{id: paused_id}} =
               InboundChannels.resolve_for_delivery(paused.inbound_route, ingress(paused))

      assert paused_id == paused.id

      assert {:revoked, %{id: revoked_id}} =
               InboundChannels.resolve_for_delivery(revoked.inbound_route, ingress(revoked))

      assert revoked_id == revoked.id

      assert InboundChannels.resolve_for_delivery(draft.inbound_route, ingress(draft)) ==
               {:error, :no_channel}
    end

    test "matches pending_verification and awaiting_first_message channels" do
      for state <- [:pending_verification, :awaiting_first_message] do
        channel = insert_inbound_channel(state: state)

        assert {:ok, _} =
                 InboundChannels.resolve_for_delivery(channel.inbound_route, ingress(channel))
      end
    end
  end

  describe "mark_received/2" do
    test "promotes pending_verification and awaiting_first_message to active" do
      for state <- [:pending_verification, :awaiting_first_message] do
        channel = insert_inbound_channel(state: state)
        at = hours_ago(1)

        assert {:ok, updated} = InboundChannels.mark_received(channel, at)
        assert updated.state == :active
        assert updated.last_received_at == at
        assert updated.verified_at == at
      end

      assert length(audit_events(:channel_state_changed)) == 2
    end

    test "keeps an existing verified_at when promoting" do
      verified_at = hours_ago(5)
      channel = insert_inbound_channel(state: :awaiting_first_message, verified_at: verified_at)

      assert {:ok, updated} = InboundChannels.mark_received(channel)
      assert updated.verified_at == verified_at
    end

    test "leaves active and paused states alone and clears the quiet notice" do
      for state <- [:active, :paused] do
        channel = insert_inbound_channel(state: state, last_received_at: hours_ago(100))
        {:ok, channel} = InboundChannels.mark_quiet_notified(channel)
        assert channel.quiet_notified_at

        assert {:ok, updated} = InboundChannels.mark_received(channel)
        assert updated.state == state
        assert is_nil(updated.quiet_notified_at)
        assert DateTime.diff(DateTime.utc_now(), updated.last_received_at) < 5
      end

      assert audit_events(:channel_state_changed) == []
    end

    test "broadcasts on the channel and organization topics" do
      channel = insert_inbound_channel(state: :active)
      InboundChannels.subscribe(channel)
      InboundChannels.subscribe_tenant(channel.tenant_id)

      assert {:ok, _} = InboundChannels.mark_received(channel)
      assert_receive {:channel_updated, id}
      assert_receive {:channel_updated, ^id}
      assert id == channel.id
    end

    test "does not reactivate a channel revoked or paused since it was loaded" do
      for {action, expected} <- [
            {&InboundChannels.revoke/1, :revoked},
            {&InboundChannels.pause/1, :paused}
          ] do
        stale = insert_inbound_channel(state: :awaiting_first_message)
        {:ok, _} = action.(stale)

        assert {:error, %Ecto.Changeset{} = changeset} = InboundChannels.mark_received(stale)
        assert Keyword.has_key?(changeset.errors, :state)

        current = Repo.reload!(stale)
        assert current.state == expected
        assert is_nil(current.last_received_at)
      end

      refute Enum.any?(audit_events(:channel_state_changed), &(&1.payload["to"] == "active"))
    end
  end

  describe "quiet channels" do
    test "list_quiet_channels/1 respects the window and the notified stamp" do
      quiet = insert_inbound_channel(state: :active, last_received_at: hours_ago(100))
      recent = insert_inbound_channel(state: :active, last_received_at: hours_ago(10))

      custom = insert_inbound_channel(state: :active, last_received_at: hours_ago(10))
      {:ok, custom} = InboundChannels.update_channel(custom, %{quiet_after_hours: 8})

      never_received = insert_inbound_channel(state: :active)
      paused = insert_inbound_channel(state: :paused, last_received_at: hours_ago(100))

      notified = insert_inbound_channel(state: :active, last_received_at: hours_ago(100))
      {:ok, _} = InboundChannels.mark_quiet_notified(notified, hours_ago(50))

      stale_notice = insert_inbound_channel(state: :active, last_received_at: hours_ago(100))
      {:ok, _} = InboundChannels.mark_quiet_notified(stale_notice, hours_ago(200))

      ids = InboundChannels.list_quiet_channels() |> Enum.map(& &1.id) |> Enum.sort()

      assert ids == Enum.sort([quiet.id, custom.id, stale_notice.id])
      refute recent.id in ids
      refute never_received.id in ids
      refute paused.id in ids
      refute notified.id in ids
    end

    test "list_quiet_channels/1 honours an explicit clock" do
      channel = insert_inbound_channel(state: :active, last_received_at: hours_ago(10))

      assert InboundChannels.list_quiet_channels() == []

      assert [%{id: id}] =
               InboundChannels.list_quiet_channels(DateTime.add(DateTime.utc_now(), 70, :hour))

      assert id == channel.id
    end

    test "check_quiet_channels/1 notifies once per quiet period" do
      channel =
        insert_inbound_channel(
          state: :active,
          last_received_at: hours_ago(100),
          public_address: "support@acme.example.com"
        )

      Phoenix.PubSub.subscribe(Custyard.PubSub, "operator:notifications")
      InboundChannels.subscribe(channel)

      assert {:ok, 1} = InboundChannels.check_quiet_channels()

      assert_receive {:channel_quiet, id}
      assert id == channel.id
      assert_receive {:channel_updated, ^id}

      assert [event] = audit_events(:channel_quiet)
      assert event.tenant_id == channel.tenant_id
      assert event.payload["channel_id"] == channel.id
      assert event.payload["public_address"] == "support@acme.example.com"
      assert event.payload["quiet_after_hours"] == 72
      assert {:ok, _, _} = DateTime.from_iso8601(event.payload["last_received_at"])
      refute inspect(event.payload) =~ channel.ingress_token

      assert %DateTime{} = reload(channel).quiet_notified_at

      # Same quiet period: nothing further.
      assert {:ok, 0} = InboundChannels.check_quiet_channels()
      refute_receive {:channel_quiet, _}
      assert [_] = audit_events(:channel_quiet)

      # Mail arrives, then the channel goes quiet again: a fresh notice.
      {:ok, _} = InboundChannels.mark_received(reload(channel), hours_ago(80))
      assert {:ok, 1} = InboundChannels.check_quiet_channels()
      assert_receive {:channel_quiet, ^id}
      assert length(audit_events(:channel_quiet)) == 2
    end

    test "check_quiet_channels/1 sends the operator notice when email is enabled" do
      channel =
        insert_inbound_channel(
          state: :active,
          last_received_at: hours_ago(100),
          public_address: "support@acme.example.com"
        )

      configure_tenant_email(channel.tenant_id)
      insert_operator_account(role: "admin", tenant_id: channel.tenant_id)

      Application.put_env(:custyard, :email_enabled, true)
      on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)

      assert {:ok, 1} = InboundChannels.check_quiet_channels()

      assert_email_sent(fn email ->
        assert email.subject == "Inbound channel quiet: support@acme.example.com"
      end)
    end

    test "check_quiet_channels/1 is a no-op without quiet channels" do
      insert_inbound_channel(state: :active, last_received_at: hours_ago(1))
      assert {:ok, 0} = InboundChannels.check_quiet_channels()
      assert audit_events(:channel_quiet) == []
    end
  end

  describe "check_sending_domain/2" do
    setup do
      original_config = Application.get_env(:custyard, :lettermint)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
        Application.delete_env(:custyard, :lettermint_mock_domains)
      end)

      :ok
    end

    defp stage_domains(domains) do
      Application.put_env(:custyard, :lettermint_mock_domains, domains)
    end

    test "stores the Lettermint status, case-insensitively, with an audit event" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")
      operator = insert_operator_account(role: "admin")
      InboundChannels.subscribe(channel)

      stage_domains([
        %{"id" => "d0", "domain" => "other.example.com", "status" => "failed_verification"},
        %{"id" => "d1", "domain" => "ACME.Example.com", "status" => "verified"}
      ])

      assert InboundChannels.sending_domain_summary(channel) == :unchecked

      assert {:ok, updated} = InboundChannels.check_sending_domain(channel, operator: operator)
      assert updated.sending_domain_status == "verified"
      assert %DateTime{} = updated.sending_domain_checked_at
      assert InboundChannels.sending_domain_verified?(updated)
      assert InboundChannels.sending_domain_summary(updated) == :verified

      assert [event] = audit_events(:channel_sending_domain_checked)
      assert event.payload["channel_id"] == channel.id
      assert event.payload["domain"] == "acme.example.com"
      assert event.payload["status"] == "verified"
      assert event.payload["operator_id"] == operator.id

      assert_receive {:channel_updated, id}
      assert id == channel.id
    end

    test "records not_found when the domain is absent" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")
      stage_domains([%{"id" => "d1", "domain" => "acme.example.org", "status" => "verified"}])

      assert {:ok, updated} = InboundChannels.check_sending_domain(channel)
      assert updated.sending_domain_status == "not_found"
      refute InboundChannels.sending_domain_verified?(updated)
      assert InboundChannels.sending_domain_summary(updated) == :not_found
    end

    test "a separate sending domain preserves the public mailbox and checks that domain" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")
      ingress = InboundChannels.ingress_address(channel)

      assert {:ok, changed} =
               InboundChannels.update_channel(channel, %{sending_domain: "mail.acme.example.com"})

      assert changed.public_address == channel.public_address
      assert InboundChannels.ingress_address(changed) == ingress
      assert InboundChannels.from_address(changed) == "support@mail.acme.example.com"

      stage_domains([%{"domain" => "mail.acme.example.com", "status" => "verified"}])
      assert {:ok, verified} = InboundChannels.check_sending_domain(changed)
      assert verified.sending_domain_status == "verified"

      assert {:ok, cleared} = InboundChannels.update_channel(verified, %{sending_domain: ""})
      assert InboundChannels.from_address(cleared) == "support@acme.example.com"
      assert is_nil(cleared.sending_domain_status)
    end

    test "changing the sending domain clears verification and roundtrip evidence" do
      channel = insert_inbound_channel()
      operator = insert_operator_account(role: "admin")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, connection} = Custyard.EmailSetup.ensure_connection(operator, channel.tenant_id)

      connection
      |> Ecto.Changeset.change(
        last_signed_inbound_at: now,
        last_reply_accepted_at: now,
        last_reply_delivered_at: now,
        last_returning_reply_at: now
      )
      |> Repo.update!()

      channel =
        channel |> InboundChannel.sending_domain_changeset("verified", now) |> Repo.update!()

      {:ok, changed} =
        InboundChannels.update_channel(channel, %{sending_domain: "mail.acme.example.com"},
          operator: operator
        )

      assert is_nil(changed.sending_domain_status)
      assert is_nil(changed.sending_domain_checked_at)
      fresh = Custyard.EmailSetup.connection(channel.tenant_id)
      assert is_nil(fresh.last_signed_inbound_at)
      assert is_nil(fresh.last_reply_accepted_at)
      assert is_nil(fresh.last_reply_delivered_at)
      assert is_nil(fresh.last_returning_reply_at)
    end

    test "summarises the intermediate statuses" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")

      for {status, summary} <- [
            {"partially_verified", :pending},
            {"pending_verification", :pending},
            {"failed_verification", :failed}
          ] do
        stage_domains([%{"id" => "d1", "domain" => "acme.example.com", "status" => status}])

        assert {:ok, updated} = InboundChannels.check_sending_domain(channel)
        assert updated.sending_domain_status == status
        assert InboundChannels.sending_domain_summary(updated) == summary
        refute InboundChannels.sending_domain_verified?(updated)
      end
    end

    test "leaves the stored status alone on an API error" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")
      stage_domains([%{"id" => "d1", "domain" => "acme.example.com", "status" => "verified"}])
      {:ok, channel} = InboundChannels.check_sending_domain(channel)

      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      assert {:error, {:api_error, 503, _}} = InboundChannels.check_sending_domain(channel)
      assert reload(channel).sending_domain_status == "verified"
      assert [_] = audit_events(:channel_sending_domain_checked)
    end

    test "rejects an unknown status from the API without storing it" do
      channel = insert_inbound_channel(public_address: "support@acme.example.com")
      stage_domains([%{"id" => "d1", "domain" => "acme.example.com", "status" => "weird"}])

      assert {:error, {:unknown_domain_status, "weird"}} =
               InboundChannels.check_sending_domain(channel)

      assert is_nil(reload(channel).sending_domain_status)
    end
  end

  describe "log_rejection/3" do
    test "stores sender, recipient, truncated subject and classification" do
      channel = insert_inbound_channel()
      route = channel.inbound_route

      assert {:ok, rejection} =
               InboundChannels.log_rejection(route, :channel_paused, %{
                 sender_email: "alice@example.com",
                 recipient: ingress(channel),
                 subject: String.duplicate("s", 600),
                 provider_delivery_id: "dlv_1",
                 inbound_channel_id: channel.id
               })

      assert rejection.classification == :channel_paused
      assert rejection.inbound_route_id == route.id
      assert rejection.tenant_id == route.tenant_id
      assert rejection.inbound_channel_id == channel.id
      assert String.length(rejection.subject) == 500

      assert [%{id: id}] = InboundChannels.list_rejections_for_route(route.id)
      assert id == rejection.id

      assert [%{id: ^id}] =
               InboundChannels.list_rejections_for_route(route.id)
    end

    test "accepts keyword attrs and a missing subject" do
      route = insert_route()

      assert {:ok, rejection} =
               InboundChannels.log_rejection(route, :no_channel, sender_email: "a@b.example")

      assert is_nil(rejection.subject)
    end

    test "returns an error instead of raising on bad attrs" do
      route = insert_route()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Ecto.Changeset{}} = InboundChannels.log_rejection(route, :bogus)

          assert {:error, %Ecto.Changeset{}} =
                   InboundChannels.log_rejection(route, :no_channel, %{
                     subject: 42,
                     sender_email: 1
                   })

          assert {:error, %Ecto.ConstraintError{}} =
                   InboundChannels.log_rejection(route, :no_channel, %{
                     inbound_channel_id: 999_999,
                     sender_email: "secret@example.com"
                   })
        end)

      assert log =~ "Inbound rejection log insert failed"
      refute log =~ "secret@example.com"
    end
  end

  describe "sweep_expired/1" do
    test "deletes only rejections older than 14 days" do
      route = insert_route()
      {:ok, old} = InboundChannels.log_rejection(route, :no_channel, %{})
      {:ok, edge} = InboundChannels.log_rejection(route, :no_channel, %{})
      {:ok, fresh} = InboundChannels.log_rejection(route, :no_channel, %{})

      old |> Ecto.Changeset.change(inserted_at: hours_ago(15 * 24)) |> Repo.update!()
      edge |> Ecto.Changeset.change(inserted_at: hours_ago(13 * 24)) |> Repo.update!()

      assert %{rejections: 1, verifications: 0, tokens: 0} = InboundChannels.sweep_expired()

      refute Repo.get(InboundChannelRejection, old.id)
      assert Repo.get(InboundChannelRejection, edge.id)
      assert Repo.get(InboundChannelRejection, fresh.id)
    end

    test "clears only expired verification captures" do
      expired = insert_inbound_channel()
      {:ok, expired} = InboundChannels.capture_verification(expired, %{code: "1"})
      backdate!(expired, verification_expires_at: hours_ago(1))

      live = insert_inbound_channel()
      {:ok, live} = InboundChannels.capture_verification(live, %{code: "2"})

      assert %{verifications: 1} = InboundChannels.sweep_expired()

      assert is_nil(reload(expired).verification_code)
      assert is_nil(reload(expired).verification_expires_at)
      assert reload(live).verification_code == "2"
    end

    test "retires only expired previous tokens" do
      expired = insert_inbound_channel(state: :active, ingress_token: @token_a)
      {:ok, expired} = InboundChannels.rotate_token(expired, grace_hours: 1)
      backdate!(expired, previous_token_expires_at: hours_ago(1))

      live = insert_inbound_channel(state: :active, ingress_token: @token_b)
      {:ok, live} = InboundChannels.rotate_token(live, grace_hours: 1)

      assert %{tokens: 1} = InboundChannels.sweep_expired()

      assert is_nil(reload(expired).previous_ingress_token)
      assert is_nil(reload(expired).previous_token_expires_at)
      assert reload(live).previous_ingress_token == @token_b
    end

    test "accepts an explicit clock" do
      channel = insert_inbound_channel(state: :active)
      {:ok, _} = InboundChannels.rotate_token(channel, grace_hours: 1)

      assert %{tokens: 0} = InboundChannels.sweep_expired()

      assert %{tokens: 1} =
               InboundChannels.sweep_expired(DateTime.add(DateTime.utc_now(), 2, :hour))
    end
  end

  describe "audit trail" do
    test "no channel audit payload carries an ingress token" do
      channel = insert_inbound_channel(ingress_token: @token_a)
      operator = insert_operator_account(role: "admin")

      {:ok, channel} =
        InboundChannels.capture_verification(channel, %{code: "1"}, operator: operator)

      {:ok, channel} = InboundChannels.confirm_verification(channel, operator: operator)
      {:ok, channel} = InboundChannels.mark_received(channel)

      {:ok, channel} =
        InboundChannels.update_channel(channel, %{display_name: "X"}, operator: operator)

      {:ok, channel} = InboundChannels.rotate_token(channel, operator: operator)
      :ok = InboundChannels.record_reveal(channel, operator: operator)
      {:ok, channel} = InboundChannels.pause(channel, operator: operator)
      {:ok, channel} = InboundChannels.resume(channel, operator: operator)
      {:ok, channel} = InboundChannels.revoke(channel, operator: operator)
      {:ok, _} = InboundChannels.delete_channel(channel, operator: operator)

      events = Repo.all(from a in AuditEvent, where: a.source == "inbound_channels")
      assert length(events) >= 10

      for event <- events do
        payload = inspect(event.payload)
        refute payload =~ @token_a, "#{event.event_type} leaked the original token"
        refute payload =~ channel.ingress_token, "#{event.event_type} leaked the rotated token"
        assert event.payload["channel_id"] == channel.id
      end
    end
  end

  describe "direct-MX channels" do
    setup do
      on_exit(fn -> Application.delete_env(:custyard, :lettermint_mock_inbound_verification) end)
      %{route: insert_route()}
    end

    defp create_mx(route, address, extra \\ %{}) do
      InboundChannels.create_channel(
        route,
        Map.merge(%{public_address: address, ingress_kind: :mx}, extra)
      )
    end

    defp verify_route!(route) do
      route = Repo.reload(route)
      {:ok, route, _} = Custyard.InboundRoutes.verify_custom_domain(route)
      route
    end

    test "the first channel sets the route's custom domain and waits for the MX record",
         %{route: route} do
      assert {:ok, channel} = create_mx(route, "support@help.acme.com", %{provider: "google"})

      assert channel.ingress_kind == :mx
      assert channel.state == :pending_verification
      assert channel.provider == nil
      assert InboundChannels.ingress_address(channel) == nil
      assert InboundChannels.masked_ingress_address(channel) == nil
      assert Repo.reload(route).lettermint_custom_domain == "help.acme.com"
    end

    test "later channels must be on the route's domain", %{route: route} do
      {:ok, _} = create_mx(route, "support@help.acme.com")

      assert {:ok, _} = create_mx(Repo.reload(route), "sales@help.acme.com")

      assert {:error, changeset} = create_mx(Repo.reload(route), "billing@other.acme.com")
      assert {msg, _} = changeset.errors[:public_address]
      assert msg =~ "must be on help.acme.com"
    end

    test "a stale copy of the route cannot move the domain away from a channel",
         %{route: route} do
      {:ok, _} = create_mx(route, "support@help.acme.com")

      assert {:error, changeset} = create_mx(route, "billing@other.acme.com")
      assert {msg, _} = changeset.errors[:public_address]
      assert msg =~ "must be on help.acme.com"
      assert Repo.reload(route).lettermint_custom_domain == "help.acme.com"

      assert {:ok, _} = create_mx(route, "sales@help.acme.com")
    end

    test "a public address with a +tag is refused", %{route: route} do
      assert {:error, changeset} = create_mx(route, "support+sales@help.acme.com")
      assert {msg, _} = changeset.errors[:public_address]
      assert msg =~ "can't contain +"
      assert Repo.reload(route).lettermint_custom_domain == nil
    end

    test "a domain a forwarding channel uses is refused", %{route: route} do
      {:ok, _} = InboundChannels.create_channel(route, %{public_address: "support@acme.com"})

      assert {:error, changeset} = create_mx(route, "help@acme.com")
      assert {msg, _} = changeset.errors[:public_address]
      assert msg =~ "dedicated subdomain"
      assert Repo.reload(route).lettermint_custom_domain == nil
    end

    test "archive copy and the ingress-address reply fallback are refused", %{route: route} do
      assert {:error, changeset} =
               create_mx(route, "support@help.acme.com", %{archive_copy: true})

      assert changeset.errors[:archive_copy]

      assert {:error, changeset} =
               create_mx(route, "support@help.acme.com", %{reply_from: "ingress_address"})

      assert changeset.errors[:reply_from]
      assert Repo.reload(route).lettermint_custom_domain == nil
    end

    test "check_mx/2 confirms the channel once Lettermint sees the record", %{route: route} do
      {:ok, channel} = create_mx(route, "support@help.acme.com")

      Application.put_env(
        :custyard,
        :lettermint_mock_inbound_verification,
        {:ok, %{"verified" => false, "found_mx_records" => ["10 mx.other.net"]}}
      )

      assert {:ok, channel, %{"verified" => false, "found_mx_records" => ["10 mx.other.net"]}} =
               InboundChannels.check_mx(channel)

      assert channel.state == :pending_verification

      Application.delete_env(:custyard, :lettermint_mock_inbound_verification)

      assert {:ok, channel, %{"verified" => true}} = InboundChannels.check_mx(channel)
      assert channel.state == :awaiting_first_message
      assert channel.verified_at
    end

    test "check_mx/2 only applies to direct-MX channels", %{route: route} do
      {:ok, channel} = InboundChannels.create_channel(route, %{public_address: "a@acme.com"})
      assert {:error, %Ecto.Changeset{}} = InboundChannels.check_mx(channel)
    end

    test "a channel on an already verified domain skips the MX wait", %{route: route} do
      {:ok, _} = create_mx(route, "support@help.acme.com")
      route = verify_route!(route)

      assert {:ok, channel} = create_mx(route, "sales@help.acme.com")
      assert channel.state == :awaiting_first_message
    end

    test "routes by public address on the custom domain, ignoring a +tag", %{route: route} do
      {:ok, channel} = create_mx(route, "support@help.acme.com")
      route = Repo.reload(route)

      assert {:ok, %{id: id}} =
               InboundChannels.resolve_for_delivery(route, "Support@Help.Acme.com")

      assert id == channel.id

      assert {:ok, %{id: ^id}} =
               InboundChannels.resolve_for_delivery(route, "support+order-42@help.acme.com")

      assert {:error, :no_channel} =
               InboundChannels.resolve_for_delivery(route, "other@help.acme.com")

      assert {:error, :no_channel} =
               InboundChannels.resolve_for_delivery(
                 route,
                 "support@#{route.lettermint_route_domain}"
               )

      {:ok, _paused} = InboundChannels.pause(channel)

      assert {:paused, %{id: ^id}} =
               InboundChannels.resolve_for_delivery(route, "support@help.acme.com")
    end

    test "a direct-MX channel's token does not route", %{route: route} do
      {:ok, channel} = create_mx(route, "support@help.acme.com")
      route = Repo.reload(route)

      assert {:error, :no_channel} =
               InboundChannels.resolve_for_delivery(
                 route,
                 "support+#{channel.ingress_token}@#{route.lettermint_route_domain}"
               )
    end

    test "forwarding channels keep the catch-all domain and their token after a custom domain lands",
         %{route: route} do
      {:ok, forward} =
        InboundChannels.create_channel(route, %{public_address: "support@acme.com"})

      address_before = InboundChannels.ingress_address(forward)

      {:ok, _} = create_mx(route, "help@help.acme.com")
      route = verify_route!(route)

      assert InboundChannels.ingress_address(reload(forward)) == address_before
      assert address_before =~ "@#{route.lettermint_route_domain}"

      assert {:ok, %{id: id}} = InboundChannels.resolve_for_delivery(route, address_before)
      assert id == forward.id
    end

    test "update_channel/3 cannot change the ingress kind", %{route: route} do
      {:ok, channel} = InboundChannels.create_channel(route, %{public_address: "a@acme.com"})

      assert {:ok, channel} = InboundChannels.update_channel(channel, %{ingress_kind: :mx})
      assert channel.ingress_kind == :forward
    end
  end
end

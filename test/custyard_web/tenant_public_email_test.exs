defmodule CustyardWeb.TenantPublicEmailTest.ApiClient do
  @behaviour Swoosh.ApiClient
  def post(_url, headers, _body, email) do
    owner = Application.fetch_env!(:custyard, :tenant_public_email_test_owner)
    send(owner, {:email, email})
    send(owner, {:tenant_delivery_headers, headers})
    {:ok, 202, [], ~s({"message_id":"test-only-message","status":"pending"})}
  end
end

defmodule CustyardWeb.TenantPublicEmailTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  import Phoenix.LiveViewTest
  alias Custyard.{EmailSetup, Intake, RateLimit, Repo, Tenants}
  alias Custyard.Intake.{ArrivalEmail, ClaimEmail, ReceiptEmail}

  setup do
    original_keys = Application.get_env(:custyard, :credential_keys)
    original_api = Application.get_env(:swoosh, :api_client)
    Application.put_env(:custyard, :credential_keys, current: :crypto.strong_rand_bytes(32))
    Application.put_env(:swoosh, :api_client, __MODULE__.ApiClient)
    Application.put_env(:custyard, :tenant_public_email_test_owner, self())
    original = Application.get_env(:custyard, :email_enabled)
    Application.put_env(:custyard, :email_enabled, true)
    RateLimit.reset()

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:custyard, :email_enabled),
        else: Application.put_env(:custyard, :email_enabled, original)

      RateLimit.reset()
      Application.put_env(:custyard, :credential_keys, original_keys)
      Application.put_env(:swoosh, :api_client, original_api)
      Application.delete_env(:custyard, :tenant_public_email_test_owner)
    end)

    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Atlas, Support",
        slug: "mail-atlas",
        custom_domain: "help.atlas.example",
        logo_url: "/uploads/logos/atlas.png",
        primary_color: "#123456"
      })

    source = insert_intake_source(tenant_id: tenant.id, name: "Atlas pricing")
    admin = insert_operator_account(role: "admin", tenant_id: tenant.id, organization_id: nil)

    {:ok, _} =
      EmailSetup.save_credentials(admin, tenant.id, %{
        "project_id" => "atlas-project",
        "project_token" => "atlas-private-token"
      })

    route =
      %Custyard.InboundRoute{}
      |> Custyard.InboundRoute.changeset(%{
        tenant_id: tenant.id,
        lettermint_route_domain: "atlas.lettermint.app"
      })
      |> Repo.insert!()

    {:ok, channel} =
      Custyard.InboundChannels.create_channel(route, %{public_address: "support@atlas.example"})

    channel = channel |> Ecto.Changeset.change(state: :active) |> Repo.update!()
    %{tenant: tenant, source: source, channel: channel, admin: admin}
  end

  test "submission receipt uses the tenant identity and canonical conversation origin", c do
    conn =
      post(build_conn(), "/i/#{c.source.key}", %{
        "submission" => %{
          "body" => "PRIVATE submitted details",
          "email" => "receipt@example.com",
          "notify" => "false"
        }
      })

    path = redirected_to(conn)
    assert_receive {:email, %Swoosh.Email{to: [{_, "receipt@example.com"}]} = email}
    assert email.text_body =~ Tenants.url(c.tenant) <> path
    assert_branding(email, c.tenant)
    refute email.text_body =~ "PRIVATE submitted details"
    refute email.html_body =~ "PRIVATE submitted details"
  end

  test "late email capture and claim confirmation preserve tenant URLs and consent", c do
    {:ok, %{conversation: conversation, access_token: token}} =
      Intake.create_intake_conversation(c.source.key, "PRIVATE support question")

    {:ok, view, _} = live(build_conn(), "/c/#{token}")

    view
    |> form("[data-testid=resume-email-form]", %{
      "capture" => %{"email" => "late@example.com", "notify" => "false"}
    })
    |> render_submit()

    assert_receive {:email, %Swoosh.Email{to: [{_, "late@example.com"}]} = receipt}
    assert receipt.text_body =~ Tenants.url(c.tenant) <> "/c/#{token}"
    assert_branding(receipt, c.tenant)
    refute Intake.get_prospect(conversation).notify_on_reply

    view
    |> form("[data-testid=resume-claim-form]", %{
      "claim" => %{"slug" => "atlas-claim", "email" => "late@example.com", "notify" => "false"}
    })
    |> render_submit()

    assert_receive {:email, %Swoosh.Email{subject: "Confirm your claim: atlas-claim"} = claim}
    assert claim.text_body =~ Tenants.url(c.tenant) <> "/claim/"
    assert claim.text_body =~ Tenants.url(c.tenant) <> "/c/#{token}"
    assert_branding(claim, c.tenant)
    [_, confirmation_token] = Regex.run(~r{/claim/([A-Za-z0-9_-]+)}, claim.text_body)

    confirmation_page =
      %{build_conn() | host: Tenants.host(c.tenant)}
      |> get("/claim/#{confirmation_token}")
      |> html_response(200)

    assert confirmation_page =~ "Atlas, Support"
    assert confirmation_page =~ ~s(src="/uploads/logos/atlas.png")
    assert confirmation_page =~ "Confirm claim"
    refute claim.text_body =~ "PRIVATE support question"
    refute claim.html_body =~ "PRIVATE support question"
    refute Intake.get_prospect(conversation).notify_on_reply
  end

  defp assert_branding(email, tenant) do
    assert {~s("Atlas, Support"), "support@atlas.example"} = email.from
    assert_receive {:tenant_delivery_headers, headers}
    assert {"x-lettermint-token", "atlas-private-token"} in headers
    assert email.text_body =~ tenant.name
    assert email.html_body =~ tenant.name
    assert email.html_body =~ Tenants.url(tenant) <> tenant.logo_url
    assert email.html_body =~ "background: #123456"
  end

  test "unconfigured tenant mail never falls back to global sending and intake remains usable",
       c do
    Repo.delete!(EmailSetup.connection(c.tenant.id))

    conn =
      post(build_conn(), "/i/#{c.source.key}", %{
        "submission" => %{"body" => "Still stored", "email" => "quiet@example.com"}
      })

    assert "/c/" <> token = redirected_to(conn)
    assert {:ok, _} = Intake.get_conversation_by_access_token(token)
    refute_receive {:tenant_delivery_headers, _}
    refute_receive {:email, %Swoosh.Email{to: [{_, "quiet@example.com"}]}}
    {:ok, view, _} = live(build_conn(), "/c/#{token}")

    view
    |> form("[data-testid=resume-claim-form]", %{
      "claim" => %{"slug" => "quiet-claim", "email" => "quiet@example.com", "notify" => "false"}
    })
    |> render_submit()

    assert render(view) =~ "we could not send the confirmation email"
    refute_receive {:email, %Swoosh.Email{to: [{_, "quiet@example.com"}]}}
  end

  test "paused support sender prevents tenant receipts", c do
    c.channel |> Ecto.Changeset.change(state: :paused) |> Repo.update!()

    assert {:error, :no_default_channel} =
             ReceiptEmail.send_receipt("buyer@example.com", c.source,
               conversation_url: Tenants.url(c.tenant) <> "/c/test-token"
             )

    refute_receive {:email, _}
  end

  test "a tenant's Lettermint token overrides the installation's SMTP adapter", c do
    put_delivery_env(Custyard.Mailer, adapter: Swoosh.Adapters.SMTP, relay: "unused.example")

    assert {:ok, _} =
             ReceiptEmail.send_receipt("buyer@example.com", c.source,
               conversation_url: Tenants.url(c.tenant) <> "/c/test-token"
             )

    assert_receive {:email, email}
    assert_branding(email, c.tenant)
  end

  test "saved default-tenant credentials reach receipts, confirmations and staff alerts" do
    put_delivery_env(Custyard.Mailer, adapter: Swoosh.Adapters.SMTP, relay: "unused.example")
    put_delivery_env(:email_from_address, "platform@example.com")
    put_delivery_env(:operator_email, "instance-operator@example.com")

    admin = insert_operator_account(role: "super_admin", tenant_id: nil, organization_id: nil)

    assert {:ok, _} =
             EmailSetup.save_credentials(admin, 1, %{
               "project_id" => "default-project",
               "project_token" => "saved-default-project-token"
             })

    source = insert_intake_source(tenant_id: 1)
    conversation = insert_conversation(source: :public_intake, tenant_id: 1)
    conversation = Repo.preload(conversation, [:organization, :contact])

    assert {:ok, _} =
             ReceiptEmail.send_receipt("buyer@example.com", source,
               conversation_url: "http://localhost/c/default-token"
             )

    assert_default_delivery("buyer@example.com")

    assert {:ok, slug, _} =
             Custyard.Slugs.claim("default-claim", "buyer@example.com", conversation)

    assert {:ok, _} =
             ClaimEmail.send_confirmation(slug,
               confirm_url: "http://localhost/claim/default-confirmation",
               conversation_url: "http://localhost/c/default-token"
             )

    assert_default_delivery("buyer@example.com")
    assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source, "A support question")
    assert_default_delivery("instance-operator@example.com")
    assert :ok = Custyard.Notifications.Email.deliver_neglect_alert(conversation, :warning)
    assert_default_delivery("instance-operator@example.com")
  end

  test "a missing selected ingress identity prevents tenant mail instead of building a nil From",
       c do
    c.channel
    |> Ecto.Changeset.change(reply_from: :ingress_address)
    |> Repo.update!()

    Custyard.InboundRoute
    |> Repo.get!(c.channel.inbound_route_id)
    |> Ecto.Changeset.change(lettermint_route_domain: nil)
    |> Repo.update!()

    # The public domain has not been verified for sending. An explicitly chosen
    # ingress identity must not silently switch to that address or the platform.
    assert is_nil(c.channel.sending_domain_status)
    conversation = insert_conversation(source: :public_intake, tenant_id: c.tenant.id)
    assert is_nil(Custyard.Conversations.reply_identity(conversation).address)
    assert {:error, :from_not_set} = Custyard.Intake.EmailBranding.delivery_settings(c.tenant.id)

    assert {:error, :from_not_set} =
             ReceiptEmail.send_receipt("buyer@example.com", c.source,
               conversation_url: Tenants.url(c.tenant) <> "/c/test-token"
             )

    refute_receive {:email, _}
    refute_receive {:tenant_delivery_headers, _}
  end

  defp assert_default_delivery(recipient) do
    assert_receive {:email, email}
    assert email.to == [{"", recipient}]
    assert elem(email.from, 1) == "platform@example.com"
    assert_receive {:tenant_delivery_headers, headers}
    assert {"x-lettermint-token", "saved-default-project-token"} in headers
  end

  defp put_delivery_env(key, value) do
    previous = Application.get_env(:custyard, key)
    Application.put_env(:custyard, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:custyard, key),
        else: Application.put_env(:custyard, key, previous)
    end)
  end

  test "tenant arrival and operational alerts reach only tenant staff with tenant credentials",
       c do
    {:ok, other} = Tenants.create_tenant(%{name: "Foreign", slug: "foreign-mail"})
    foreign = insert_operator_account(role: "agent", tenant_id: other.id, organization_id: nil)
    local = insert_operator_account(role: "agent", tenant_id: c.tenant.id, organization_id: nil)

    conversation =
      insert_conversation(
        source: :public_intake,
        tenant_id: c.tenant.id,
        subject: "PRIVATE tenant subject"
      )
      |> Repo.preload([:organization, :contact])

    expected = MapSet.new([c.admin.email, local.email])

    assert {:ok, _} = ArrivalEmail.send_arrival(conversation, c.source, "PRIVATE tenant body")
    assert_receive {:email, arrival}
    assert MapSet.new(Enum.map(arrival.to, &elem(&1, 1))) == expected
    assert arrival.text_body =~ "PRIVATE tenant body"

    assert arrival.text_body =~
             Tenants.url(c.tenant) <> "/operator/conversation/#{conversation.id}"

    refute Enum.any?(arrival.to, &(elem(&1, 1) == foreign.email))
    assert arrival.from == {~s("Atlas, Support"), "support@atlas.example"}
    assert_receive {:tenant_delivery_headers, headers}
    assert {"x-lettermint-token", "atlas-private-token"} in headers

    for send_alert <- [
          fn -> Custyard.Notifications.Email.deliver_neglect_alert(conversation, :warning) end,
          fn ->
            Custyard.Notifications.Email.deliver_delivery_failure(
              conversation,
              :bounced,
              "customer@example.com"
            )
          end,
          fn -> Custyard.Notifications.Email.deliver_channel_quiet(c.channel) end
        ] do
      assert :ok = send_alert.()
      assert_receive {:email, alert}
      assert MapSet.new(Enum.map(alert.to, &elem(&1, 1))) == expected
      assert alert.from == {~s("Atlas, Support"), "support@atlas.example"}
      assert_receive {:tenant_delivery_headers, headers}
      assert {"x-lettermint-token", "atlas-private-token"} in headers
    end
  end

  test "tenant notifications skip when staff are absent", c do
    Repo.delete!(c.admin)

    conversation =
      insert_conversation(source: :public_intake, tenant_id: c.tenant.id)
      |> Repo.preload([:organization, :contact])

    assert {:error, :no_staff} = ArrivalEmail.send_arrival(conversation, c.source, "PRIVATE")

    assert {:error, :no_staff} =
             Custyard.Notifications.Email.deliver_neglect_alert(conversation, :warning)

    refute_receive {:email, _}
  end
end

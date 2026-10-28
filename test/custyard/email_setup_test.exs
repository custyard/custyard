defmodule Custyard.EmailSetupTest do
  use Custyard.DataCase, async: false
  import Custyard.Factory
  alias Custyard.{EmailConnection, EmailSetup, InboundRoute, Repo, Tenant}
  alias Custyard.Webhooks.Dispatcher

  setup do
    keys = [
      :credential_keys,
      :lettermint_setup_client,
      :email_setup_test_provider,
      :lettermint,
      Custyard.Mailer
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:custyard, &1)})
    Application.put_env(:custyard, :credential_keys, current: :crypto.strong_rand_bytes(32))
    Application.put_env(:custyard, :lettermint_setup_client, Custyard.EmailSetupTestProvider)

    Application.put_env(:custyard, :email_setup_test_provider, %{
      pid: self(),
      project: {:ok, %{"id" => "project-1"}},
      ping: :ok
    })

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:custyard, key),
          else: Application.put_env(:custyard, key, value)
      end
    end)

    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          name: "Email tenant",
          slug: "email-#{System.unique_integer([:positive])}"
        })
      )

    admin = insert_staff_account(role: "admin", tenant_id: tenant.id)
    %{tenant: tenant, admin: admin}
  end

  test "separate tenant secrets are encrypted, redacted, preserved on blank input and never inherited",
       c do
    Application.put_env(:custyard, :lettermint, team_token: "bootstrap-team")

    Application.put_env(:custyard, Custyard.Mailer,
      adapter: Swoosh.Adapters.Lettermint,
      api_token: "bootstrap-project"
    )

    assert {:error, :not_configured} = EmailSetup.management_config(c.tenant.id)
    assert {:error, :not_configured} = EmailSetup.sending_config(c.tenant.id)
    assert {:ok, saved} = save(c)
    refute saved.project_token_ciphertext == "project-secret"
    refute inspect(saved) =~ "project-secret"
    refute inspect(saved) =~ saved.team_token_ciphertext
    assert {:ok, opts} = EmailSetup.management_config(c.tenant.id)
    assert opts[:team_token] == "team-secret"
    refute Keyword.has_key?(opts, :api_token)
    assert {:ok, opts} = EmailSetup.sending_config(c.tenant.id)
    assert opts[:api_token] == "project-secret"
    refute Keyword.has_key?(opts, :team_token)

    assert {:ok, preserved} =
             EmailSetup.save_credentials(c.admin, c.tenant.id, %{
               "project_id" => "project-1",
               "project_token" => "",
               "team_token" => ""
             })

    assert preserved.project_token_ciphertext == saved.project_token_ciphertext

    assert {:error, :unauthorized} =
             EmailSetup.save_credentials(%{role: "admin", tenant_id: 1}, c.tenant.id, %{})
  end

  test "credential encryption is required and context prevents copying secrets across tenants",
       c do
    assert {:ok, saved} = save(c)

    other =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, connection} =
      EmailSetup.ensure_connection(
        insert_staff_account(role: "admin", tenant_id: other.id),
        other.id
      )

    Repo.update!(
      Ecto.Changeset.change(connection, project_token_ciphertext: saved.project_token_ciphertext)
    )

    assert {:error, :invalid} = EmailSetup.sending_config(other.id)
    Application.delete_env(:custyard, :credential_keys)

    assert {:error, :encryption_unavailable} =
             EmailSetup.save_credentials(c.admin, c.tenant.id, %{"team_token" => "new-secret"})

    assert EmailSetup.connection(c.tenant.id).team_token_ciphertext == saved.team_token_ciphertext
  end

  test "connection checks authenticate independently without creating delivery evidence", c do
    save(c)
    assert {:ok, checked} = EmailSetup.check_connection(c.admin, c.tenant.id)
    assert checked.project_check_status == "verified"
    assert checked.sending_check_status == "verified"
    assert_receive {:provider_read, :project, "project-1", opts}
    assert opts[:team_token] == "team-secret"
    assert_receive {:provider_read, :ping, "project-secret", _}
    refute EmailSetup.summary(c.tenant.id).complete?
    assert is_nil(checked.last_reply_accepted_at)
    fixture(:project, {:error, {:provider_status, 403}})
    {:ok, checked} = EmailSetup.check_connection(c.admin, c.tenant.id)
    assert checked.project_check_status == "forbidden"
    assert checked.sending_check_status == "verified"
  end

  test "manual route import requires the selected project and locks project once connected", c do
    save(c)
    fixture(:route, {:ok, remote_route("wrong-project")})

    assert {:error, :wrong_project_or_route} =
             EmailSetup.import_route(c.admin, c.tenant.id, "route-1")

    assert EmailSetup.routes(c.tenant.id) == []
    fixture(:route, {:ok, remote_route("project-1")})
    assert {:ok, route} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")
    assert route.tenant_id == c.tenant.id
    refute Map.has_key?(route, :organization_id)
    assert {:ok, repeated} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")
    assert repeated.id == route.id

    assert {:error, changeset} =
             EmailSetup.save_credentials(c.admin, c.tenant.id, %{"project_id" => "project-2"})

    assert errors_on(changeset).project_id == [
             "cannot change while receiving routes are connected"
           ]
  end

  test "route binding checks URL, tenant, scope and live deliveries before storing a secret", c do
    save(c)
    fixture(:route, {:ok, remote_route("project-1")})
    {:ok, route} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")

    remote =
      webhook(%{
        "scope" => "route",
        "route_ids" => ["route-1"],
        "events" => ["message.inbound"],
        "url" => Custyard.InboundRoutes.callback_url(route)
      })

    fixture(:webhook, {:ok, Map.put(remote, "delivery_mode_filter", "sandbox")})

    assert {:error, :webhook_mismatch} =
             EmailSetup.bind_inbound_webhook(
               c.admin,
               c.tenant.id,
               route.id,
               "webhook-1",
               "signing-secret"
             )

    assert is_nil(Repo.reload!(route).webhook_secret_ciphertext)
    fixture(:webhook, {:ok, remote})

    assert {:ok, bound} =
             EmailSetup.bind_inbound_webhook(
               c.admin,
               c.tenant.id,
               route.id,
               "webhook-1",
               "signing-secret"
             )

    assert {:ok, "signing-secret"} = EmailSetup.inbound_secret(bound)
    refute inspect(bound) =~ "signing-secret"
    refute EmailSetup.summary(c.tenant.id).receiving?
    assert is_nil(Repo.get!(InboundRoute, route.id).webhook_verified_at)
  end

  test "imported routes initialize notification dispatch and preserve disabled consumers", c do
    save(c)
    fixture(:route, {:ok, remote_route("project-1")})
    {:ok, route} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")

    assert Enum.sort(Enum.map(route.webhooks, & &1.purpose)) == [:notification, :sender_matching]

    Phoenix.PubSub.subscribe(Custyard.PubSub, "staff:notifications")

    normalized = %{
      from: "alice@customer.example",
      to: "support@example.com",
      subject: "Imported route notification",
      body: "Please help",
      message_id: "<imported-route@customer.example>",
      in_reply_to: nil,
      references: nil,
      headers: %{},
      source: :lettermint,
      metadata: %{authentication: %{"dkim" => "pass", "dmarc" => "pass"}}
    }

    channel =
      insert_inbound_channel(tenant_id: c.tenant.id, inbound_route_id: route.id, state: :active)

    assert {:ok, thread} = Dispatcher.dispatch(route, normalized, channel: channel)
    assert_receive {:new_message, id}, 1_000
    assert id == thread.id

    notification = Enum.find(route.webhooks, &(&1.purpose == :notification))
    {:ok, _} = Custyard.InboundRoutes.disable_webhook(notification)
    assert {:ok, repeated} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")
    refute Enum.find(repeated.webhooks, &(&1.purpose == :notification)).enabled

    Repo.delete!(notification)
    assert {:ok, repaired} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")
    assert Enum.find(repaired.webhooks, &(&1.purpose == :notification)).enabled
    assert length(repaired.webhooks) == 2
  end

  test "status binding requires selected project, callback URL and every handled event", c do
    {:ok, connection} = save(c)

    remote =
      webhook(%{
        "scope" => "project",
        "project_ids" => ["project-1"],
        "events" => EmailSetup.status_events(),
        "url" => EmailSetup.status_callback_url(connection)
      })

    fixture(:webhook, {:ok, Map.put(remote, "project_ids", ["another-project"])})

    assert {:error, :webhook_mismatch} =
             EmailSetup.bind_status_webhook(c.admin, c.tenant.id, "webhook-1", "status-secret")

    for scope <- ["route", "team"] do
      fixture(:webhook, {:ok, Map.put(remote, "scope", scope)})

      assert {:error, :status_webhook_scope} =
               EmailSetup.bind_status_webhook(c.admin, c.tenant.id, "webhook-1", "status-secret")

      refute EmailSetup.connection(c.tenant.id).status_secret_ciphertext
      assert EmailSetup.error_message(:status_webhook_scope) =~ "choose Projects"
    end

    fixture(:webhook, {:ok, remote})

    assert {:ok, connection} =
             EmailSetup.bind_status_webhook(c.admin, c.tenant.id, "webhook-1", "status-secret")

    assert {:ok, "status-secret"} = EmailSetup.status_secret(connection)
    assert is_nil(connection.last_reply_delivered_at)
    assert Repo.aggregate(EmailConnection, :count) == 1
  end

  test "portal reply defaults are unambiguous, tenant owned and active", c do
    assert {:error, :no_default_channel} = EmailSetup.default_reply_channel(c.tenant.id)
    first = reply_channel(c.tenant.id, "one@example.com")
    assert {:ok, %{id: id}} = EmailSetup.default_reply_channel(c.tenant.id)
    assert id == first.id
    second = reply_channel(c.tenant.id, "two@example.com")
    assert {:error, :ambiguous_channels} = EmailSetup.default_reply_channel(c.tenant.id)
    assert {:ok, _} = EmailSetup.set_default_channel(c.admin, c.tenant.id, to_string(second.id))
    assert {:ok, %{id: id}} = EmailSetup.default_reply_channel(c.tenant.id)
    assert id == second.id
    other_tenant = insert_tenant()
    foreign = reply_channel(other_tenant.id, "foreign@example.com")

    assert {:error, :no_default_channel} =
             EmailSetup.set_default_channel(c.admin, c.tenant.id, foreign.id)

    Repo.update!(Ecto.Changeset.change(second, state: :paused))
    assert {:error, :no_default_channel} = EmailSetup.default_reply_channel(c.tenant.id)
    assert {:ok, _} = EmailSetup.set_default_channel(c.admin, c.tenant.id, "")
    assert {:ok, %{id: id}} = EmailSetup.default_reply_channel(c.tenant.id)
    assert id == first.id
  end

  test "a legacy route does not prevent the first explicit project selection", c do
    reply_channel(c.tenant.id, "legacy@example.com")
    assert {:ok, %{project_id: "project-1"}} = save(c)
  end

  test "changing a legacy sender records the evidence boundary before the wizard is opened", c do
    channel = reply_channel(c.tenant.id, "legacy-support@example.com")
    customer = insert_organization(tenant_id: c.tenant.id)
    thread = insert_thread(organization_id: customer.id)

    old_reply =
      insert_message(
        thread_id: thread.id,
        source: :staff,
        delivery_status: :sent,
        lettermint_message_id: "old-legacy-reply"
      )

    assert is_nil(EmailSetup.connection(c.tenant.id))

    assert {:ok, _} =
             Custyard.InboundChannels.update_channel(channel, %{reply_from: :ingress_address},
               staff: c.admin
             )

    assert EmailSetup.connection(c.tenant.id).reply_evidence_after_message_id >= old_reply.id
    EmailSetup.record_reply_accepted(old_reply)
    refute EmailSetup.summary(c.tenant.id).sending?
  end

  test "provider checks cannot restore success after credentials change in flight", c do
    save(c)

    fixture(:project, fn ->
      {:ok, _} = EmailSetup.save_credentials(c.admin, c.tenant.id, %{"team_token" => "rotated"})
      {:ok, %{"id" => "project-1"}}
    end)

    assert {:error, :stale_configuration} = EmailSetup.check_connection(c.admin, c.tenant.id)
    current = EmailSetup.connection(c.tenant.id)
    assert current.project_check_status == "unchecked"
    assert current.sending_check_status == "unchecked"
  end

  test "route import rejects a project changed while provider lookup was running", c do
    save(c)

    fixture(:route, fn ->
      {:ok, _} = EmailSetup.save_credentials(c.admin, c.tenant.id, %{"project_id" => "project-2"})
      {:ok, remote_route("project-1")}
    end)

    assert {:error, :stale_configuration} =
             EmailSetup.import_route(c.admin, c.tenant.id, "route-1")

    assert EmailSetup.routes(c.tenant.id) == []
  end

  test "revocation during provider lookup prevents webhook binding", c do
    {:ok, connection} = save(c)

    fixture(:webhook, fn ->
      Repo.update!(Custyard.StaffAccount.role_changeset(c.admin, %{role: "agent"}))

      {:ok,
       webhook(%{
         "scope" => "project",
         "project_ids" => ["project-1"],
         "events" => EmailSetup.status_events(),
         "url" => EmailSetup.status_callback_url(connection)
       })}
    end)

    assert {:error, :unauthorized} =
             EmailSetup.bind_status_webhook(c.admin, c.tenant.id, "webhook-1", "late-secret")

    assert is_nil(EmailSetup.connection(c.tenant.id).status_secret_ciphertext)
    assert {:error, :unauthorized} = EmailSetup.save_credentials(c.admin, c.tenant.id, %{})
  end

  test "an expired session claim cannot perform local setup mutations", c do
    save(c)

    Repo.update!(
      Ecto.Changeset.change(c.admin,
        session_claim: Custyard.StaffAccount.generate_session_claim()
      )
    )

    assert {:error, :unauthorized} = EmailSetup.set_default_channel(c.admin, c.tenant.id, "")
    assert {:error, :unauthorized} = EmailSetup.ensure_connection(c.admin, c.tenant.id)
    assert {:error, :unauthorized} = EmailSetup.check_connection(c.admin, c.tenant.id)
  end

  test "an old webhook lookup cannot overwrite a replacement signing secret", c do
    save(c)
    fixture(:route, {:ok, remote_route("project-1")})
    {:ok, route} = EmailSetup.import_route(c.admin, c.tenant.id, "route-1")

    fixture(:webhook, fn ->
      Repo.update!(Ecto.Changeset.change(route, webhook_secret_ciphertext: "replacement"))

      {:ok,
       webhook(%{
         "scope" => "route",
         "route_ids" => ["route-1"],
         "events" => ["message.inbound"],
         "url" => Custyard.InboundRoutes.callback_url(route)
       })}
    end)

    assert {:error, :stale_configuration} =
             EmailSetup.bind_inbound_webhook(
               c.admin,
               c.tenant.id,
               route.id,
               "webhook-1",
               "old-secret"
             )

    assert Repo.reload!(route).webhook_secret_ciphertext == "replacement"
  end

  defp reply_channel(tenant_id, address) do
    route =
      Repo.insert!(
        InboundRoute.changeset(%InboundRoute{}, %{
          tenant_id: tenant_id,
          lettermint_route_domain: "route.lettermint.app"
        })
      )

    {:ok, channel} = Custyard.InboundChannels.create_channel(route, %{public_address: address})
    Repo.update!(Ecto.Changeset.change(channel, state: :active))
  end

  defp save(c),
    do:
      EmailSetup.save_credentials(c.admin, c.tenant.id, %{
        "project_id" => "project-1",
        "project_token" => "project-secret",
        "team_token" => "team-secret"
      })

  defp fixture(key, result),
    do:
      Application.put_env(
        :custyard,
        :email_setup_test_provider,
        Map.put(Application.fetch_env!(:custyard, :email_setup_test_provider), key, result)
      )

  defp remote_route(project),
    do: %{
      "id" => "route-1",
      "project_id" => project,
      "route_type" => "inbound",
      "inbound_route_domain" => "real.lettermint.app",
      "inbound_address" => "compat@inbound.lettermint.co"
    }

  defp webhook(attrs),
    do:
      Map.merge(
        %{
          "id" => "webhook-1",
          "enabled" => true,
          "delivery_mode_filter" => "live",
          "has_basic_auth" => false
        },
        attrs
      )
end

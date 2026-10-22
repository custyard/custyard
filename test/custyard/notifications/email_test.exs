defmodule Custyard.Notifications.EmailTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Notifications.Email

  setup do
    # Create test data with preloaded associations
    org = insert_organization(name: "Acme Corp")
    contact = insert_contact(organization_id: org.id, name: "Alice", email: "alice@acme.com")

    conv =
      insert_conversation(
        organization_id: org.id,
        contact_id: contact.id,
        subject: "Urgent support needed"
      )
      |> Repo.preload([:organization, :contact])

    {:ok, org: org, contact: contact, conversation: conv}
  end

  describe "deliver_neglect_alert/2" do
    test "logs alert when email is disabled", %{conversation: conv} do
      # Default config has email_enabled=false
      assert Email.deliver_neglect_alert(conv, :warning) == :ok
      assert_no_email_sent()
    end

    test "sends email when email is enabled", %{conversation: conv} do
      # Temporarily enable email
      original_value = Application.get_env(:custyard, :email_enabled)
      Application.put_env(:custyard, :email_enabled, true)

      on_exit(fn ->
        if original_value do
          Application.put_env(:custyard, :email_enabled, original_value)
        else
          Application.delete_env(:custyard, :email_enabled)
        end
      end)

      assert Email.deliver_neglect_alert(conv, :warning) == :ok

      assert_email_sent(fn email ->
        assert email.subject =~ "[WARNING]"
        assert email.subject =~ "Urgent support needed"
        assert email.html_body =~ "Acme Corp"
        assert email.html_body =~ "Alice"
        assert email.text_body =~ "Urgent support needed"
      end)
    end

    test "sends critical alert with different styling", %{conversation: conv} do
      Application.put_env(:custyard, :email_enabled, true)

      on_exit(fn ->
        Application.delete_env(:custyard, :email_enabled)
      end)

      assert Email.deliver_neglect_alert(conv, :critical) == :ok

      assert_email_sent(fn email ->
        assert email.subject =~ "[CRITICAL]"
        # Critical uses red color (#ef4444)
        assert email.html_body =~ "#ef4444"
      end)
    end

    test "uses configured operator email", %{conversation: conv} do
      Application.put_env(:custyard, :email_enabled, true)
      Application.put_env(:custyard, :operator_email, "ops@custyard.test")

      on_exit(fn ->
        Application.delete_env(:custyard, :email_enabled)
        Application.delete_env(:custyard, :operator_email)
      end)

      assert Email.deliver_neglect_alert(conv, :warning) == :ok

      assert_email_sent(fn email ->
        assert email.to == [{"", "ops@custyard.test"}]
      end)
    end

    test "handles missing contact gracefully", %{org: org} do
      conv =
        insert_conversation(organization_id: org.id, contact_id: nil)
        |> Repo.preload([:organization, :contact])

      Application.put_env(:custyard, :email_enabled, true)

      on_exit(fn ->
        Application.delete_env(:custyard, :email_enabled)
      end)

      assert Email.deliver_neglect_alert(conv, :warning) == :ok

      assert_email_sent(fn email ->
        assert email.html_body =~ "Unknown"
      end)
    end

    test "handles contact without name (email only)", %{org: org} do
      contact = insert_contact(organization_id: org.id, name: nil, email: "anon@example.com")

      conv =
        insert_conversation(organization_id: org.id, contact_id: contact.id)
        |> Repo.preload([:organization, :contact])

      Application.put_env(:custyard, :email_enabled, true)

      on_exit(fn ->
        Application.delete_env(:custyard, :email_enabled)
      end)

      assert Email.deliver_neglect_alert(conv, :warning) == :ok

      assert_email_sent(fn email ->
        assert email.html_body =~ "anon@example.com"
      end)
    end

    test "renders neutral label for conversations without an organization" do
      conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          subject: "Anonymous intake question"
        )
        |> Repo.preload([:organization, :contact])

      Application.put_env(:custyard, :email_enabled, true)

      on_exit(fn ->
        Application.delete_env(:custyard, :email_enabled)
      end)

      assert Email.deliver_neglect_alert(conv, :critical) == :ok

      assert_email_sent(fn email ->
        assert email.subject =~ "Anonymous intake question"
        assert email.html_body =~ "Unlinked prospect"
        assert email.text_body =~ "Unlinked prospect"
      end)
    end

    test "logs alert without crashing for conversations without an organization" do
      conv =
        insert_conversation(organization_id: nil, source: :disambiguation)
        |> Repo.preload([:organization, :contact])

      # Default config has email_enabled=false, so this exercises the log stub
      assert Email.deliver_neglect_alert(conv, :warning) == :ok
      assert_no_email_sent()
    end
  end

  describe "deliver_channel_quiet/1" do
    setup %{org: org} do
      last_received_at = ~U[2026-10-10 08:30:00Z]

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          state: :active,
          public_address: "support@acme.example.com",
          last_received_at: last_received_at
        )
        |> Repo.preload(:organization)

      {:ok, channel: channel}
    end

    test "logs instead of sending when email is disabled", %{channel: channel} do
      # The stub logs at info, below the test logger level; what matters here
      # is that nothing is sent and nothing sensitive reaches the log.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Email.deliver_channel_quiet(channel) == :ok
        end)

      refute log =~ "support@acme.example.com"
      refute log =~ channel.ingress_token
      assert_no_email_sent()
    end

    test "sends the notice when email is enabled", %{channel: channel} do
      Application.put_env(:custyard, :email_enabled, true)
      Application.put_env(:custyard, :operator_email, "ops@custyard.test")

      on_exit(fn ->
        Application.delete_env(:custyard, :email_enabled)
        Application.delete_env(:custyard, :operator_email)
      end)

      assert Email.deliver_channel_quiet(channel) == :ok

      assert_email_sent(fn email ->
        assert email.to == [{"", "ops@custyard.test"}]
        assert email.subject == "Inbound channel quiet: support@acme.example.com"

        for body <- [email.html_body, email.text_body] do
          assert body =~ "support@acme.example.com"
          assert body =~ "Acme Corp"
          assert body =~ "2026-10-10 08:30 UTC"
          assert body =~ "72 hours"
          assert body =~ "silently disabled"
          refute body =~ channel.ingress_token
        end
      end)
    end

    test "escapes the address in the HTML body", %{channel: channel} do
      Application.put_env(:custyard, :email_enabled, true)
      on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)

      channel = %{channel | public_address: "a<b@acme.example.com"}
      assert Email.deliver_channel_quiet(channel) == :ok

      assert_email_sent(fn email ->
        refute email.html_body =~ "a<b@"
        assert email.html_body =~ "a&lt;b@acme.example.com"
      end)
    end

    test "copes with an organization that is not preloaded", %{channel: channel} do
      Application.put_env(:custyard, :email_enabled, true)
      on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)

      channel = %{channel | organization: %Ecto.Association.NotLoaded{}}
      assert Email.deliver_channel_quiet(channel) == :ok

      assert_email_sent(fn email ->
        assert email.text_body =~ "Unlinked prospect"
      end)
    end
  end

  describe "deliver_delivery_failure/3" do
    test "logs instead of sending when email is disabled", %{conversation: conv} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Email.deliver_delivery_failure(conv, :bounced, "alice@acme.com") == :ok
        end)

      refute log =~ "alice@acme.com"
      refute log =~ "Urgent support needed"
      assert_no_email_sent()
    end

    test "names the conversation, organization and recipient", %{conversation: conv} do
      Application.put_env(:custyard, :email_enabled, true)
      on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)

      assert Email.deliver_delivery_failure(conv, :bounced, "alice@acme.com") == :ok

      assert_email_sent(fn email ->
        assert email.subject == "Reply bounced: Urgent support needed"

        for body <- [email.html_body, email.text_body] do
          assert body =~ "Acme Corp"
          assert body =~ "alice@acme.com"
          assert body =~ "does not stop sending"
        end
      end)
    end

    test "marks a CC recipient and says the customer's copy is unaffected", %{
      conversation: conv
    } do
      Application.put_env(:custyard, :email_enabled, true)
      on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)

      assert Email.deliver_delivery_failure(conv, :bounced, "boss@acme.com", :cc) == :ok

      assert_email_sent(fn email ->
        assert email.text_body =~ "Recipient: boss@acme.com (CC)"
        assert email.text_body =~ "customer's own copy is tracked separately"
        assert email.html_body =~ "boss@acme.com (CC)"
      end)
    end

    test "explains a suppression and escapes the recipient", %{conversation: conv} do
      Application.put_env(:custyard, :email_enabled, true)
      on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)

      assert Email.deliver_delivery_failure(conv, :suppressed, "a<b@acme.com") == :ok

      assert_email_sent(fn email ->
        assert email.subject == "Reply suppressed: Urgent support needed"
        assert email.text_body =~ "suppression list"
        refute email.html_body =~ "a<b@"
        assert email.html_body =~ "a&lt;b@acme.com"
      end)
    end
  end
end

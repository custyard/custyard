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
  end
end

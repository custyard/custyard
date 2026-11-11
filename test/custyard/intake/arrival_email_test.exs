defmodule Custyard.Intake.ArrivalEmailTest do
  # Rewrites bucket config and the :email_enabled flag — sequential only.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Intake.ArrivalEmail
  alias Custyard.{Intake, RateLimit}

  setup do
    configure_tenant_email(factory_tenant_id())
    Custyard.Tenants.add_host(factory_tenant_id(), "intake.test")
    insert_staff_account(tenant_id: factory_tenant_id(), email: "ops@example.com")
    RateLimit.reset()
    original_buckets = Application.get_env(:custyard, :rate_limit_buckets)
    original_enabled = Application.get_env(:custyard, :email_enabled)
    original_staff = Application.get_env(:custyard, :staff_email)

    Application.put_env(:custyard, :email_enabled, true)
    Application.put_env(:custyard, :staff_email, "ops@example.com")

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original_buckets)

      if original_enabled == nil do
        Application.delete_env(:custyard, :email_enabled)
      else
        Application.put_env(:custyard, :email_enabled, original_enabled)
      end

      if original_staff == nil do
        Application.delete_env(:custyard, :staff_email)
      else
        Application.put_env(:custyard, :staff_email, original_staff)
      end

      RateLimit.reset()
    end)

    :ok
  end

  defp fixture(overrides \\ []) do
    source = insert_intake_source(overrides)
    thread = insert_thread(source: :public_intake, subject: "Pricing question")
    %{source: source, thread: thread}
  end

  describe "send_arrival/3" do
    test "delivers to the configured staff address" do
      %{source: source, thread: thread} = fixture()

      assert {:ok, _} = ArrivalEmail.send_arrival(thread, source, "How much for 50 seats?")

      assert_email_sent(fn email ->
        assert {_name, "ops@example.com"} = hd(email.to)
        assert email.subject =~ "Pricing question"
        assert email.subject =~ source.name
        assert email.text_body =~ "How much for 50 seats?"
        assert email.html_body =~ "How much for 50 seats?"
      end)
    end

    test "carries a direct link to the staff thread view" do
      %{source: source, thread: thread} = fixture()

      assert {:ok, _} = ArrivalEmail.send_arrival(thread, source, "hello")

      expected =
        Custyard.Tenants.url(Custyard.Tenants.get_tenant!(factory_tenant_id())) <>
          "/app/threads/#{thread.id}"

      assert_email_sent(fn email ->
        assert email.text_body =~ expected
        assert email.html_body =~ expected
      end)
    end

    test "identifies the intake source by name and key" do
      %{source: source, thread: thread} = fixture(name: "Pricing CTA", key: "pricing")

      assert {:ok, _} = ArrivalEmail.send_arrival(thread, source, "hello")

      assert_email_sent(fn email ->
        assert email.text_body =~ "Pricing CTA"
        assert email.text_body =~ "pricing"
        assert email.html_body =~ "Pricing CTA"
      end)
    end

    test "sends nothing when email notifications are disabled" do
      Application.put_env(:custyard, :email_enabled, false)
      %{source: source, thread: thread} = fixture()

      assert {:error, :disabled} = ArrivalEmail.send_arrival(thread, source, "hello")

      assert_no_email_sent()
    end

    test "stops sending once the per-source bucket is exhausted" do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(
        :custyard,
        :rate_limit_buckets,
        Keyword.put(original, :intake_arrival_email, limit: 1, window_ms: 3_600_000)
      )

      %{source: source, thread: thread} = fixture()

      assert {:ok, _} = ArrivalEmail.send_arrival(thread, source, "first")
      assert {:error, :rate_limited} = ArrivalEmail.send_arrival(thread, source, "second")
    end

    test "the rate bucket is keyed per source, not globally" do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(
        :custyard,
        :rate_limit_buckets,
        Keyword.put(original, :intake_arrival_email, limit: 1, window_ms: 3_600_000)
      )

      %{source: source_a, thread: thread} = fixture()
      source_b = insert_intake_source()

      assert {:ok, _} = ArrivalEmail.send_arrival(thread, source_a, "first")
      assert {:ok, _} = ArrivalEmail.send_arrival(thread, source_b, "first for b")
    end
  end

  describe "compose/3 content safety" do
    test "strips newlines from prospect text before it reaches the subject" do
      %{source: source, thread: _} = fixture()

      thread =
        insert_thread(
          source: :public_intake,
          subject: "Hello\r\nBcc: victim@example.com"
        )

      email = ArrivalEmail.compose(thread, source, "body")

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end

    test "escapes prospect HTML in the body" do
      %{source: source, thread: thread} = fixture()

      email = ArrivalEmail.compose(thread, source, "<script>alert(1)</script>")

      refute email.html_body =~ "<script>"
      assert email.html_body =~ "&lt;script&gt;"
    end

    test "truncates a long submission to an excerpt" do
      %{source: source, thread: thread} = fixture()
      body = String.duplicate("a", 900)

      email = ArrivalEmail.compose(thread, source, body)

      refute email.text_body =~ String.duplicate("a", 900)
      assert email.text_body =~ "…"
    end

    # Thread.changeset/2 requires :subject, so a persisted row never
    # has a nil one. compose/3 is a public seam, so it still guards.
    test "tolerates a thread with no derived subject" do
      %{source: source, thread: _} = fixture()

      thread = %Custyard.Thread{
        tenant_id: factory_tenant_id(),
        id: 1,
        subject: nil,
        source: :public_intake
      }

      email = ArrivalEmail.compose(thread, source, "body")

      assert email.subject =~ "(no subject)"
    end
  end

  describe "intake submission wiring" do
    test "creating an intake thread notifies the staff" do
      source = insert_intake_source(name: "Pricing CTA")

      assert {:ok, %{thread: thread}} =
               create_intake(source.key, "We need SSO for 200 users")

      assert_email_sent(fn email ->
        assert {_name, "ops@example.com"} = hd(email.to)
        assert email.subject =~ "Pricing CTA"
        assert email.text_body =~ "We need SSO for 200 users"
        assert email.text_body =~ "/app/threads/#{thread.id}"
      end)
    end

    test "a disabled notifier does not break submission" do
      Application.put_env(:custyard, :email_enabled, false)
      source = insert_intake_source()

      assert {:ok, %{thread: _, prospect: _, access_token: _}} =
               create_intake(source.key, "hello")

      assert_no_email_sent()
    end

    test "an exhausted arrival bucket does not break submission" do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(
        :custyard,
        :rate_limit_buckets,
        Keyword.put(original, :intake_arrival_email, limit: 0, window_ms: 3_600_000)
      )

      source = insert_intake_source()

      assert {:ok, %{thread: _, prospect: _, access_token: _}} =
               create_intake(source.key, "hello")

      assert_no_email_sent()
    end
  end

  defp create_intake(key, body, opts \\ []),
    do:
      Intake.create_intake_thread(
        key,
        body,
        Keyword.put(opts, :tenant_id, Custyard.Factory.factory_tenant_id())
      )
end

defmodule Custyard.Intake.ArrivalEmailTest do
  # Rewrites bucket config and the :email_enabled flag — sequential only.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Intake.ArrivalEmail
  alias Custyard.{Intake, RateLimit}

  setup do
    RateLimit.reset()
    original_buckets = Application.get_env(:custyard, :rate_limit_buckets)
    original_enabled = Application.get_env(:custyard, :email_enabled)
    original_operator = Application.get_env(:custyard, :operator_email)

    Application.put_env(:custyard, :email_enabled, true)
    Application.put_env(:custyard, :operator_email, "ops@example.com")

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original_buckets)

      if original_enabled == nil do
        Application.delete_env(:custyard, :email_enabled)
      else
        Application.put_env(:custyard, :email_enabled, original_enabled)
      end

      if original_operator == nil do
        Application.delete_env(:custyard, :operator_email)
      else
        Application.put_env(:custyard, :operator_email, original_operator)
      end

      RateLimit.reset()
    end)

    :ok
  end

  defp fixture(overrides \\ []) do
    source = insert_intake_source(overrides)
    conversation = insert_conversation(source: :public_intake, subject: "Pricing question")
    %{source: source, conversation: conversation}
  end

  describe "send_arrival/3" do
    test "delivers to the configured operator address" do
      %{source: source, conversation: conversation} = fixture()

      assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source, "How much for 50 seats?")

      assert_email_sent(fn email ->
        assert {_name, "ops@example.com"} = hd(email.to)
        assert email.subject =~ "Pricing question"
        assert email.subject =~ source.name
        assert email.text_body =~ "How much for 50 seats?"
        assert email.html_body =~ "How much for 50 seats?"
      end)
    end

    test "carries a direct link to the operator conversation view" do
      %{source: source, conversation: conversation} = fixture()

      assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source, "hello")

      expected = CustyardWeb.Endpoint.url() <> "/operator/conversation/#{conversation.id}"

      assert_email_sent(fn email ->
        assert email.text_body =~ expected
        assert email.html_body =~ expected
      end)
    end

    test "identifies the intake source by name and key" do
      %{source: source, conversation: conversation} = fixture(name: "Pricing CTA", key: "pricing")

      assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source, "hello")

      assert_email_sent(fn email ->
        assert email.text_body =~ "Pricing CTA"
        assert email.text_body =~ "pricing"
        assert email.html_body =~ "Pricing CTA"
      end)
    end

    test "sends nothing when email notifications are disabled" do
      Application.put_env(:custyard, :email_enabled, false)
      %{source: source, conversation: conversation} = fixture()

      assert {:error, :disabled} = ArrivalEmail.send_arrival(conversation, source, "hello")

      assert_no_email_sent()
    end

    test "stops sending once the per-source bucket is exhausted" do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(
        :custyard,
        :rate_limit_buckets,
        Keyword.put(original, :intake_arrival_email, limit: 1, window_ms: 3_600_000)
      )

      %{source: source, conversation: conversation} = fixture()

      assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source, "first")
      assert {:error, :rate_limited} = ArrivalEmail.send_arrival(conversation, source, "second")
    end

    test "the rate bucket is keyed per source, not globally" do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(
        :custyard,
        :rate_limit_buckets,
        Keyword.put(original, :intake_arrival_email, limit: 1, window_ms: 3_600_000)
      )

      %{source: source_a, conversation: conversation} = fixture()
      source_b = insert_intake_source()

      assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source_a, "first")
      assert {:ok, _} = ArrivalEmail.send_arrival(conversation, source_b, "first for b")
    end
  end

  describe "compose/3 content safety" do
    test "strips newlines from prospect text before it reaches the subject" do
      %{source: source, conversation: _} = fixture()

      conversation =
        insert_conversation(
          source: :public_intake,
          subject: "Hello\r\nBcc: victim@example.com"
        )

      email = ArrivalEmail.compose(conversation, source, "body")

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end

    test "escapes prospect HTML in the body" do
      %{source: source, conversation: conversation} = fixture()

      email = ArrivalEmail.compose(conversation, source, "<script>alert(1)</script>")

      refute email.html_body =~ "<script>"
      assert email.html_body =~ "&lt;script&gt;"
    end

    test "truncates a long submission to an excerpt" do
      %{source: source, conversation: conversation} = fixture()
      body = String.duplicate("a", 900)

      email = ArrivalEmail.compose(conversation, source, body)

      refute email.text_body =~ String.duplicate("a", 900)
      assert email.text_body =~ "…"
    end

    # Conversation.changeset/2 requires :subject, so a persisted row never
    # has a nil one. compose/3 is a public seam, so it still guards.
    test "tolerates a conversation with no derived subject" do
      %{source: source, conversation: _} = fixture()
      conversation = %Custyard.Conversation{id: 1, subject: nil, source: :public_intake}

      email = ArrivalEmail.compose(conversation, source, "body")

      assert email.subject =~ "(no subject)"
    end
  end

  describe "intake submission wiring" do
    test "creating an intake conversation notifies the operator" do
      source = insert_intake_source(name: "Pricing CTA")

      assert {:ok, %{conversation: conversation}} =
               Intake.create_intake_conversation(source.key, "We need SSO for 200 users")

      assert_email_sent(fn email ->
        assert {_name, "ops@example.com"} = hd(email.to)
        assert email.subject =~ "Pricing CTA"
        assert email.text_body =~ "We need SSO for 200 users"
        assert email.text_body =~ "/operator/conversation/#{conversation.id}"
      end)
    end

    test "a disabled notifier does not break submission" do
      Application.put_env(:custyard, :email_enabled, false)
      source = insert_intake_source()

      assert {:ok, %{conversation: _, prospect: _, access_token: _}} =
               Intake.create_intake_conversation(source.key, "hello")

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

      assert {:ok, %{conversation: _, prospect: _, access_token: _}} =
               Intake.create_intake_conversation(source.key, "hello")

      assert_no_email_sent()
    end
  end
end

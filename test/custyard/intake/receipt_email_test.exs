defmodule Custyard.Intake.ReceiptEmailTest do
  # Rewrites bucket config and the :email_enabled flag — sequential only.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Intake.ReceiptEmail
  alias Custyard.RateLimit

  @conversation_url "http://localhost/c/test-access-token"

  setup do
    RateLimit.reset()
    original_buckets = Application.get_env(:custyard, :rate_limit_buckets)
    original_enabled = Application.get_env(:custyard, :email_enabled)

    Application.put_env(:custyard, :email_enabled, true)

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original_buckets)

      if original_enabled == nil do
        Application.delete_env(:custyard, :email_enabled)
      else
        Application.put_env(:custyard, :email_enabled, original_enabled)
      end

      RateLimit.reset()
    end)

    :ok
  end

  defp send!(email \\ "buyer@example.com", source \\ nil) do
    source = source || insert_intake_source(name: "Pricing CTA")
    ReceiptEmail.send_receipt(email, source, conversation_url: @conversation_url)
  end

  describe "send_receipt/3" do
    test "delivers the resume URL to the captured address" do
      assert {:ok, _} = send!()

      assert_email_sent(fn email ->
        assert {_name, "buyer@example.com"} = hd(email.to)
        assert email.text_body =~ @conversation_url
        assert email.html_body =~ @conversation_url
      end)
    end

    test "names the intake source the prospect came through" do
      source = insert_intake_source(name: "Enterprise pricing")

      assert {:ok, _} = send!("buyer@example.com", source)

      assert_email_sent(fn email ->
        assert email.text_body =~ "Enterprise pricing"
        assert email.html_body =~ "Enterprise pricing"
      end)
    end

    test "sends nothing when email notifications are disabled" do
      Application.put_env(:custyard, :email_enabled, false)

      assert {:error, :disabled} = send!()
      assert_no_email_sent()
    end

    test "stops sending once the per-address bucket is exhausted" do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(
        :custyard,
        :rate_limit_buckets,
        Keyword.put(original, :intake_receipt_email, limit: 1, window_ms: 86_400_000)
      )

      assert {:ok, _} = send!("repeat@example.com")
      assert {:error, :rate_limited} = send!("repeat@example.com")
      # A different prospect is unaffected — the bucket is per address.
      assert {:ok, _} = send!("other@example.com")
    end

    test "requires the caller to supply the conversation URL" do
      source = insert_intake_source()

      assert_raise KeyError, fn ->
        ReceiptEmail.send_receipt("buyer@example.com", source, [])
      end
    end
  end

  describe "compose/3 content safety" do
    # This mail goes to an attacker-choosable address, so it must be
    # useless as a spam relay: no submitted content may reach it.
    test "carries no prospect-supplied content" do
      source = insert_intake_source(name: "Pricing CTA")

      email = ReceiptEmail.compose("buyer@example.com", source, @conversation_url)

      assert email.subject == "We received your message"
      refute email.subject =~ "buyer@example.com"
    end

    test "escapes an operator-configured source name in the HTML body" do
      source = insert_intake_source(name: "A&B <Sales>")

      email = ReceiptEmail.compose("buyer@example.com", source, @conversation_url)

      refute email.html_body =~ "<Sales>"
      assert email.html_body =~ "&amp;B"
    end
  end
end

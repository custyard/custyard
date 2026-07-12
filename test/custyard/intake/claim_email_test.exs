defmodule Custyard.Intake.ClaimEmailTest do
  # Rewrites bucket config and the mailer adapter — sequential only.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Auth.Token
  alias Custyard.Intake.ClaimEmail
  alias Custyard.{RateLimit, Settings, Slug, Slugs}

  @confirm_url "http://localhost/c/test-confirmation-token"
  @resume_url "http://localhost/r/test-resume-token"

  setup do
    RateLimit.reset()
    original = Application.get_env(:custyard, :rate_limit_buckets)

    Application.put_env(
      :custyard,
      :rate_limit_buckets,
      Keyword.put(original, :claim_email_send, limit: 5, window_ms: 86_400_000)
    )

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original)
      RateLimit.reset()
    end)

    :ok
  end

  defp claim!(email \\ "buyer@example.com") do
    conversation = insert_conversation(source: :public_intake)
    {:ok, slug, token} = Slugs.claim("acme-corp", email, conversation)
    %{conversation: conversation, slug: slug, token: token}
  end

  defp send!(slug) do
    ClaimEmail.send_confirmation(slug, confirm_url: @confirm_url, resume_url: @resume_url)
  end

  describe "composition" do
    test "delivers to the anchor email with the platform From and both URLs" do
      %{slug: slug} = claim!()

      assert {:ok, _metadata} = send!(slug)

      assert_email_sent(fn email ->
        assert email.to == [{"", "buyer@example.com"}]

        {from_name, from_address} = email.from
        assert from_name == "Custyard"

        assert from_address ==
                 Application.get_env(:custyard, :email_from_address, "noreply@custyard.local")

        assert email.subject == "Confirm your claim: acme-corp"

        # Text and HTML bodies both carry the slug and the two platform URLs.
        assert email.text_body =~ "acme-corp"
        assert email.text_body =~ @confirm_url
        assert email.text_body =~ @resume_url
        assert email.html_body =~ "acme-corp"
        assert email.html_body =~ @confirm_url
        assert email.html_body =~ @resume_url
      end)
    end

    test "never carries prospect-supplied content" do
      conversation = insert_conversation(source: :public_intake)

      insert_message(
        conversation_id: conversation.id,
        source: :prospect,
        sender_email: nil,
        body: "PROSPECT-SECRET buy my crypto https://evil.example/spam"
      )

      {:ok, slug, _token} = Slugs.claim("spam-free", "buyer@example.com", conversation)

      assert {:ok, _} = send!(slug)

      assert_email_sent(fn email ->
        refute email.text_body =~ "PROSPECT-SECRET"
        refute email.text_body =~ "evil.example"
        refute email.html_body =~ "PROSPECT-SECRET"
        refute email.html_body =~ "evil.example"
        refute email.subject =~ "PROSPECT-SECRET"
        # assert_email_sent requires a truthy return from the function.
        true
      end)
    end

    test "uses the branding name as From display name, header-disciplined" do
      {:ok, _} = Settings.update_branding(%{name: "Acme, Inc."})
      %{slug: slug} = claim!()

      assert {:ok, _} = send!(slug)

      assert_email_sent(fn email ->
        {from_name, _} = email.from
        # RFC 5322 specials force the quoted form (shared Headers discipline).
        assert from_name == ~s{"Acme, Inc."}
      end)
    end
  end

  describe "rate bounding" do
    test "at most 5 sends per anchor email per day" do
      %{slug: slug} = claim!()

      for _i <- 1..5 do
        assert {:ok, _} = send!(slug)
        # Consume the delivery message so the final refute sees a clean box.
        assert_email_sent(fn email -> email.subject == "Confirm your claim: acme-corp" end)
      end

      assert {:error, :rate_limited} = send!(slug)
      refute_email_sent()

      # A different anchor email has its own budget.
      other = insert_slug(slug: "other-slug", email: "other@example.com")
      assert {:ok, _} = send!(other)
    end
  end

  describe "mailer failure" do
    test "leaves the claim intact and re-sendable" do
      %{slug: slug, token: token} = claim!()

      original = Application.get_env(:custyard, Custyard.Mailer)
      Application.put_env(:custyard, Custyard.Mailer, adapter: Custyard.FailingMailerAdapter)
      on_exit(fn -> Application.put_env(:custyard, Custyard.Mailer, original) end)

      assert {:error, :smtp_down} = send!(slug)

      # The claim row is untouched: still claimed, token hash still live.
      reloaded = Repo.get!(Slug, slug.id)
      assert reloaded.status == :claimed
      assert reloaded.confirmation_token_hash == Token.hash(token)

      # Re-sendable: rotate a fresh token and deliver once the mailer heals.
      Application.put_env(:custyard, Custyard.Mailer, original)
      assert {:ok, rotated, new_token} = Slugs.rotate_confirmation_token(reloaded)
      assert {:ok, _} = send!(rotated)
      assert_email_sent(fn email -> assert email.text_body =~ @confirm_url end)

      # And the rotated token still confirms.
      assert {:ok, _} = Slugs.confirm(new_token)
    end
  end
end

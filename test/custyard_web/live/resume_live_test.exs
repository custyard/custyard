defmodule CustyardWeb.ResumeLiveTest do
  # Shares the rate-limit ETS table and rewrites bucket config — sequential only.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Custyard.{Conversation, Conversations, Intake, Message, Prospect, RateLimit, Repo}

  @generous [limit: 1000, window_ms: 60_000]
  @unavailable "/r/unavailable"

  setup do
    RateLimit.reset()
    original = Application.get_env(:custyard, :rate_limit_buckets)
    put_buckets()

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original)
      RateLimit.reset()
    end)

    :ok
  end

  defp put_buckets(overrides \\ []) do
    base = [
      intake_get: @generous,
      intake_post: @generous,
      resume_mount: @generous,
      resume_reply: @generous,
      email_capture: @generous,
      claim_submit: @generous,
      claim_confirm: @generous,
      claim_email_send: @generous
    ]

    Application.put_env(:custyard, :rate_limit_buckets, Keyword.merge(base, overrides))
  end

  defp create_intake!(body \\ "Hello, I need help with X") do
    source = insert_intake_source(mode: :active)
    {:ok, result} = Intake.create_intake_conversation(source.key, body)
    result
  end

  defp message_count(conversation_id) do
    Repo.one(from m in Message, where: m.conversation_id == ^conversation_id, select: count())
  end

  describe "mount and thread rendering" do
    test "a fresh session shows the thread including operator replies" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        body: "Operator here, happy to help",
        sender_email: "operator-private@example.com"
      )

      # Cookie-less fresh conn: the URL alone is the credential.
      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")

      assert html =~ ~s(data-testid="resume-conversation")
      assert html =~ "Hello, I need help with X"
      assert html =~ "Operator here, happy to help"
      assert html =~ "Support Team"
      # Sender identity never renders — not even the operator address.
      refute html =~ "operator-private@example.com"
    end

    test "internal notes are never rendered" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        body: "INTERNAL: lowball them",
        is_internal_note: true
      )

      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")

      refute html =~ "INTERNAL: lowball them"
    end

    test "a conversation id alone grants nothing (IDOR)" do
      %{conversation: conversation} = create_intake!()

      for guess <- [
            "#{conversation.id}",
            "0",
            "999999",
            "id-#{conversation.id}",
            String.duplicate("a", 43)
          ] do
        assert {:error, {:redirect, %{to: @unavailable}}} =
                 live(build_conn(), ~p"/r/#{guess}")
      end
    end

    test "a revoked prospect gets the same uniform unavailable page as an invalid token" do
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _prospect} = Intake.revoke_resume_access(conversation)

      assert {:error, {:redirect, %{to: @unavailable}}} = live(build_conn(), ~p"/r/#{token}")

      # Identical failure rendering for every class: same redirect target,
      # one static page.
      html = build_conn() |> get(@unavailable) |> html_response(200)
      assert html =~ "Conversation unavailable"
      refute html =~ conversation.subject
    end

    test "the email prompt renders only while no email is captured" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")
      assert html =~ ~s(data-testid="resume-email-prompt")
      refute html =~ ~s(data-testid="resume-notify-toggle")

      {:ok, _conversation} = Intake.capture_email(conversation, "captured@example.com")

      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")
      refute html =~ ~s(data-testid="resume-email-prompt")
      assert html =~ ~s(data-testid="resume-notify-toggle")
    end

    test "mounts are rate limited per client IP with a graceful redirect" do
      put_buckets(resume_mount: [limit: 2, window_ms: 60_000])
      %{resume_token: token} = create_intake!()

      # First page view: disconnected + connected mount = the whole budget.
      {:ok, _view, _html} = live(build_conn(), ~p"/r/#{token}")

      assert {:error, {:redirect, %{to: @unavailable}}} = live(build_conn(), ~p"/r/#{token}")
    end
  end

  describe "prospect replies" do
    test "a reply reactivates a resolved conversation and mirrors inbound semantics" do
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _conversation} = Conversations.update_conversation(conversation, %{state: :resolved})

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      html =
        view
        |> form(~s([data-testid="resume-reply-form"]), %{"reply" => %{"body" => "I am back!"}})
        |> render_submit()

      assert html =~ "I am back!"

      reloaded = Repo.get!(Conversation, conversation.id)
      assert reloaded.state == :active
      assert reloaded.last_customer_action_at
      assert reloaded.cached_score > 0

      messages =
        Repo.all(from m in Message, where: m.conversation_id == ^conversation.id, order_by: m.id)

      reply = List.last(messages)
      assert reply.source == :prospect
      assert reply.origin == :public_intake
      assert reply.sender_email == nil
      assert reply.delivery_status == nil
      refute reply.is_internal_note
    end

    test "reply bodies are validated and bounded like intake submissions" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      view
      |> form(~s([data-testid="resume-reply-form"]), %{"reply" => %{"body" => "   "}})
      |> render_submit()

      assert message_count(conversation.id) == 1

      oversized = String.duplicate("a", 100_001)

      view
      |> form(~s([data-testid="resume-reply-form"]), %{"reply" => %{"body" => oversized}})
      |> render_submit()

      assert message_count(conversation.id) == 1
    end

    test "replies over websocket are rate limited by token hash with no message row" do
      put_buckets(resume_reply: [limit: 2, window_ms: 60_000])
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      for n <- 1..2 do
        view
        |> form(~s([data-testid="resume-reply-form"]), %{"reply" => %{"body" => "Reply #{n}"}})
        |> render_submit()
      end

      assert message_count(conversation.id) == 3

      html =
        view
        |> form(~s([data-testid="resume-reply-form"]), %{"reply" => %{"body" => "Reply 3"}})
        |> render_submit()

      assert html =~ "replying too quickly"
      assert message_count(conversation.id) == 3
    end

    test "mid-session revocation shuts the mounted view down to the uniform page" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      # The revocation broadcast alone re-authenticates the mounted socket:
      # no further mutation is needed for the view to halt, and no reply
      # could land afterwards (the context refuses revoked prospects too).
      {:ok, _prospect} = Intake.revoke_resume_access(conversation)

      assert_redirect(view, @unavailable)
      assert message_count(conversation.id) == 1
    end

    test "token rotation shuts down sockets mounted under the old token" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      # An operator rotating a leaked link must cut off already-open tabs:
      # the socket re-reads the prospect, sees its mount-time hash no longer
      # matches, and halts to the uniform page — it neither keeps write
      # access nor keeps receiving operator replies over PubSub.
      {:ok, %{resume_token: _new_token}} = Intake.rotate_resume_token(conversation)

      assert_redirect(view, @unavailable)
      assert message_count(conversation.id) == 1
    end
  end

  describe "email capture" do
    test "capture links a matching contact without rendering any linkage" do
      org = insert_organization(name: "Acme Rockets Inc", domain: "acme-rockets.example")

      contact =
        insert_contact(organization_id: org.id, email: "buyer@acme-rockets.example")

      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      html =
        view
        |> form(~s([data-testid="resume-email-form"]), %{
          "capture" => %{"email" => "buyer@acme-rockets.example", "notify" => "true"}
        })
        |> render_submit()

      # The conversation linked...
      reloaded = Repo.get!(Conversation, conversation.id)
      assert reloaded.organization_id == org.id
      assert reloaded.contact_id == contact.id

      # ...and nothing on the page says so.
      refute html =~ "Acme Rockets Inc"
      refute html =~ "acme-rockets.example"

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "buyer@acme-rockets.example"
      assert prospect.notify_on_reply
    end

    test "the capture response is byte-identical for contact match, domain match, and no match" do
      org = insert_organization(name: "Match Target", domain: "match-target.example")
      insert_contact(organization_id: org.id, email: "known@match-target.example")

      shared_body = "Same message everywhere"
      fixed_time = ~U[2026-07-01 12:00:00Z]

      captures = [
        {"known@match-target.example", create_intake!(shared_body)},
        {"someone-else@match-target.example", create_intake!(shared_body)},
        {"stranger@unrelated.example", create_intake!(shared_body)}
      ]

      # Pin every rendered timestamp so the comparison sees only
      # linkage-dependent differences (there must be none).
      Repo.update_all(Message, set: [inserted_at: fixed_time])

      [contact_html, domain_html, none_html] =
        for {email, %{resume_token: token}} <- captures do
          {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

          view
          |> form(~s([data-testid="resume-email-form"]), %{
            "capture" => %{"email" => email, "notify" => "true"}
          })
          |> render_submit()
          |> normalize_live_html()
        end

      assert contact_html == domain_html
      assert domain_html == none_html
    end

    test "capture attempts are rate limited per IP, counting failures" do
      put_buckets(email_capture: [limit: 1, window_ms: 60_000])
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      # First attempt consumes the budget even though it fails validation.
      view
      |> form(~s([data-testid="resume-email-form"]), %{
        "capture" => %{"email" => "not-an-email", "notify" => "false"}
      })
      |> render_submit()

      html =
        view
        |> form(~s([data-testid="resume-email-form"]), %{
          "capture" => %{"email" => "fine@example.com", "notify" => "false"}
        })
        |> render_submit()

      assert html =~ "Too many attempts"
      assert Repo.get_by!(Prospect, conversation_id: conversation.id).email == nil
    end
  end

  describe "notification toggle" do
    test "the prospect can change the notification choice at any time" do
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _conversation} = Intake.capture_email(conversation, "toggle@example.com")

      {:ok, view, html} = live(build_conn(), ~p"/r/#{token}")
      assert html =~ ~s(data-testid="resume-notify-toggle")

      view
      |> element(~s([data-testid="resume-notify-form"]))
      |> render_change(%{"notify" => "true"})

      assert Repo.get_by!(Prospect, conversation_id: conversation.id).notify_on_reply

      view
      |> element(~s([data-testid="resume-notify-form"]))
      |> render_change(%{"notify" => "false"})

      refute Repo.get_by!(Prospect, conversation_id: conversation.id).notify_on_reply
    end

    test "the toggle shares the :email_capture bucket" do
      put_buckets(email_capture: [limit: 1, window_ms: 60_000])
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _conversation} = Intake.capture_email(conversation, "toggle@example.com")

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      view
      |> element(~s([data-testid="resume-notify-form"]))
      |> render_change(%{"notify" => "true"})

      html =
        view
        |> element(~s([data-testid="resume-notify-form"]))
        |> render_change(%{"notify" => "false"})

      assert html =~ "Too many changes"
      # The denied toggle did not write.
      assert Repo.get_by!(Prospect, conversation_id: conversation.id).notify_on_reply
    end
  end

  describe "slug claim panel" do
    import Swoosh.TestAssertions

    alias Custyard.{Slug, Slugs}

    defp submit_claim(view, slug, email, notify \\ "false") do
      view
      |> element(~s([data-testid="resume-claim-form"]))
      |> render_submit(%{"claim" => %{"slug" => slug, "email" => email, "notify" => notify}})
    end

    test "offers the claim form when the conversation has no live claim" do
      %{resume_token: token} = create_intake!()

      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")

      assert html =~ ~s(data-testid="resume-claim-panel")
      assert html =~ ~s(data-testid="resume-claim-form")
      # The spec's framing: the email anchors the claim.
      assert html =~ "Where do we confirm the claim?"
      assert html =~ ~s(data-testid="resume-claim-notify")
    end

    test "submit claims the slug, captures the email, honors notify, and sends the email" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      html = submit_claim(view, "Acme-Corp", "Buyer@Example.com", "true")

      # The claim committed, normalized.
      claim = Slugs.get_claim_for_conversation(conversation.id)
      assert claim.slug == "acme-corp"
      assert claim.email == "buyer@example.com"
      assert claim.status == :claimed

      # Email captured with the notify choice honored.
      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "buyer@example.com"
      assert prospect.notify_on_reply

      # The confirmation email carries the slug, the /c confirm URL, and
      # the /r resume URL the prospect already holds.
      assert_email_sent(fn email ->
        assert email.text_body =~ "acme-corp"
        assert email.text_body =~ "/c/"
        assert email.text_body =~ "/r/#{token}"
      end)

      # The panel flips to the provisional state with an expiry countdown.
      assert html =~ ~s(data-testid="resume-claim-status-provisional")
      assert html =~ ~s(data-testid="resume-claim-expiry")
      assert html =~ "expires in about"
    end

    test "notify unchecked leaves notifications off" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")
      submit_claim(view, "quiet-corp", "quiet@example.com", "false")

      refute Repo.get_by!(Prospect, conversation_id: conversation.id).notify_on_reply
    end

    test "claim-then-capture ordering: a failed claim captures nothing" do
      taken = create_intake!("Original claim")
      {:ok, _slug, _token} = Slugs.claim("contested", "first@example.com", taken.conversation)

      %{conversation: conversation, resume_token: token} = create_intake!("Second prospect")

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")
      html = submit_claim(view, "contested", "second@example.com")

      # The changeset error renders; nothing was captured or sent.
      assert html =~ "is already claimed"
      assert Repo.get_by!(Prospect, conversation_id: conversation.id).email == nil
      refute_email_sent()
      assert is_nil(Slugs.get_claim_for_conversation(conversation.id))
    end

    test "claim-then-capture ordering: a capture failure never loses the claim" do
      # Write-once email already captured — the capture step inside the
      # claim submit returns :already_captured, and the claim must stand.
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _} = Intake.capture_email(conversation, "first@example.com")

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")
      html = submit_claim(view, "sturdy-claim", "different@example.com")

      claim = Slugs.get_claim_for_conversation(conversation.id)
      assert claim.slug == "sturdy-claim"
      # The claim anchors to the address it was submitted with...
      assert claim.email == "different@example.com"
      # ...while the write-once prospect email stands untouched.
      assert Repo.get_by!(Prospect, conversation_id: conversation.id).email ==
               "first@example.com"

      # The confirmation email still goes out to the claim's anchor.
      assert_email_sent(fn email ->
        assert email.to == [{"", "different@example.com"}]
      end)

      assert html =~ ~s(data-testid="resume-claim-status-provisional")
    end

    test "claiming with notify on an already-captured email still opts into notifications" do
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _} = Intake.capture_email(conversation, "first@example.com")
      refute Repo.get_by!(Prospect, conversation_id: conversation.id).notify_on_reply

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")
      submit_claim(view, "notify-me", "different@example.com", "true")

      # capture_email returned :already_captured (write-once email), but a
      # checked notify box is an explicit opt-in and must not be dropped.
      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "first@example.com"
      assert prospect.notify_on_reply
    end

    test "a rate-limited confirmation email changes the claim flash, not the claim" do
      put_buckets(claim_email_send: [limit: 1, window_ms: 60_000])

      # Exhaust the per-email daily budget from another conversation
      # claiming with the same anchor email.
      first = create_intake!("Earlier claim")
      {:ok, first_view, _html} = live(build_conn(), ~p"/r/#{first.resume_token}")
      submit_claim(first_view, "first-claim", "shared@example.com")
      assert_email_sent()

      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")
      html = submit_claim(view, "quota-hit", "shared@example.com")

      # The claim committed and the panel flips to provisional...
      assert Slugs.get_claim_for_conversation(conversation.id).status == :claimed
      assert html =~ ~s(data-testid="resume-claim-status-provisional")

      # ...but no email went out, and the flash must say so instead of
      # telling the prospect to check for one.
      refute_email_sent()
      refute html =~ "Check your email"
      assert html =~ "confirmation email limit is reached"
    end

    test "conversation and resume access survive claim expiry with a fresh claim form" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, slug, _confirmation_token} =
        Slugs.claim("short-lived", "buyer@example.com", conversation)

      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(from(s in Slug, where: s.id == ^slug.id), set: [expires_at: past])

      assert Slugs.delete_expired_claims() == 1

      # Expiry released only the slug row: the resume link still
      # authenticates and the thread still renders...
      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")
      assert html =~ "Hello, I need help with X"

      # ...and the panel offers a fresh claim form.
      assert html =~ ~s(data-testid="resume-claim-form")
      refute html =~ ~s(data-testid="resume-claim-status-provisional")
    end

    test "prefills the claim email from a captured prospect email" do
      %{conversation: conversation, resume_token: token} = create_intake!()
      {:ok, _} = Intake.capture_email(conversation, "captured@example.com")

      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")

      assert html =~ ~s(value="captured@example.com")
    end

    test "shows the confirmed state once the claim confirms" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, _slug, confirmation_token} =
        Slugs.claim("all-done", "buyer@example.com", conversation)

      {:ok, _} = Slugs.confirm(confirmation_token)

      {:ok, _view, html} = live(build_conn(), ~p"/r/#{token}")

      assert html =~ ~s(data-testid="resume-claim-status-confirmed")
      assert html =~ "all-done"
      refute html =~ ~s(data-testid="resume-claim-form")
    end

    test "resend rotates the confirmation token and sends a fresh email" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, claim, _confirmation_token} =
        Slugs.claim("resend-me", "buyer@example.com", conversation)

      {:ok, view, html} = live(build_conn(), ~p"/r/#{token}")
      assert html =~ ~s(data-testid="resume-claim-resend")

      result =
        view |> element(~s([data-testid="resume-claim-resend"])) |> render_click()

      assert result =~ "Confirmation email sent"

      # Rotated: the stored hash changed, and the fresh email carries a
      # working link.
      rotated = Repo.get!(Slug, claim.id)
      refute rotated.confirmation_token_hash == claim.confirmation_token_hash

      assert_email_sent(fn email ->
        assert email.text_body =~ "resend-me"
        assert email.text_body =~ "/c/"
      end)
    end

    test "resend is bucket-limited and a denied resend does not rotate the token" do
      put_buckets(claim_email_send: [limit: 1, window_ms: 60_000])
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, claim, _confirmation_token} =
        Slugs.claim("throttled", "buyer@example.com", conversation)

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      # First resend consumes the whole budget.
      view |> element(~s([data-testid="resume-claim-resend"])) |> render_click()
      after_first = Repo.get!(Slug, claim.id)
      refute after_first.confirmation_token_hash == claim.confirmation_token_hash

      # Second resend is denied BEFORE rotation — the emailed link survives.
      result =
        view |> element(~s([data-testid="resume-claim-resend"])) |> render_click()

      assert result =~ "Confirmation email limit reached"

      assert Repo.get!(Slug, claim.id).confirmation_token_hash ==
               after_first.confirmation_token_hash
    end

    test "the claim event is bounded by the IP-keyed :claim_submit bucket" do
      put_buckets(claim_submit: [limit: 1, window_ms: 60_000])
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, view, _html} = live(build_conn(), ~p"/r/#{token}")

      # First attempt (invalid slug) burns the budget — every attempt
      # counts on the anonymous surface.
      submit_claim(view, "x", "buyer@example.com")

      html = submit_claim(view, "valid-name", "buyer@example.com")

      assert html =~ "Too many claim attempts"
      assert is_nil(Slugs.get_claim_for_conversation(conversation.id))
    end
  end

  describe "retention purge" do
    test "a purged conversation's resume URL lands on the uniform unavailable page" do
      %{conversation: conversation, resume_token: token} = create_intake!()

      {:ok, _conversation} = Conversations.update_conversation(conversation, %{state: :resolved})

      # Past the 365-day public-intake retention bound
      backdated =
        DateTime.utc_now()
        |> DateTime.add(-366 * 24 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(
        from(c in Conversation, where: c.id == ^conversation.id),
        set: [updated_at: backdated]
      )

      assert Conversations.cleanup_resolved_conversations(90) == 1

      # The prospect cascaded away with the conversation, so the token no
      # longer resolves...
      assert Intake.get_conversation_by_resume_token(token) == {:error, :not_found}

      # ...and the resume URL renders the same unavailable page as an
      # invalid token — no validity oracle.
      assert {:error, {:redirect, %{to: @unavailable}}} =
               live(build_conn(), ~p"/r/#{token}")
    end
  end

  # Strips the per-socket identifiers LiveView bakes into the DOM so two
  # renders can be compared byte-for-byte on content.
  defp normalize_live_html(html) do
    html
    |> String.replace(~r/id="phx-[^"]+"/, ~s(id="phx-ID"))
    |> String.replace(~r/data-phx-session="[^"]*"/, ~s(data-phx-session=""))
    |> String.replace(~r/data-phx-static="[^"]*"/, ~s(data-phx-static=""))
  end
end

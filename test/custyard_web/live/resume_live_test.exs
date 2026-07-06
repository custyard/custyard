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

  # Strips the per-socket identifiers LiveView bakes into the DOM so two
  # renders can be compared byte-for-byte on content.
  defp normalize_live_html(html) do
    html
    |> String.replace(~r/id="phx-[^"]+"/, ~s(id="phx-ID"))
    |> String.replace(~r/data-phx-session="[^"]*"/, ~s(data-phx-session=""))
    |> String.replace(~r/data-phx-static="[^"]*"/, ~s(data-phx-static=""))
  end
end

defmodule CustyardWeb.IntakeControllerTest do
  # Shares the rate-limit ETS table and rewrites bucket config — sequential only.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Custyard.{Conversation, Message, OperatorAccount, Prospect, RateLimit, Repo}

  # The exact CSP the :browser pipeline ships today — the public surface must
  # not weaken or change it (bundled app.js/app.css only, no inline scripts).
  @csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data: https:; connect-src 'self' wss:; frame-ancestors 'none'"

  @generous [limit: 1000, window_ms: 60_000]

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
      conversation_mount: @generous,
      conversation_reply: @generous,
      email_capture: @generous,
      claim_submit: @generous,
      claim_confirm: @generous,
      claim_email_send: @generous
    ]

    Application.put_env(:custyard, :rate_limit_buckets, Keyword.merge(base, overrides))
  end

  defp row_counts do
    %{
      conversations: Repo.aggregate(Conversation, :count),
      messages: Repo.aggregate(Message, :count),
      prospects: Repo.aggregate(Prospect, :count)
    }
  end

  describe "GET /i/:source_key (active)" do
    test "renders the message form without an email field", %{conn: conn} do
      source = insert_intake_source(mode: :active, headline: "Join the waitlist")

      conn = get(conn, ~p"/i/#{source.key}")
      html = html_response(conn, 200)

      assert html =~ ~s(data-testid="intake-active")
      assert html =~ "Join the waitlist"
      assert html =~ ~s(name="submission[body]")
      refute html =~ ~s(name="submission[email]")
    end

    test "renders operator instance branding with Custyard fallback", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      html = conn |> get(~p"/i/#{source.key}") |> html_response(200)

      assert html =~ ~s(data-testid="intake-instance-name")
      assert html =~ "Custyard"
      # No operator or portal chrome on the intake layout
      refute html =~ ~s(data-testid="layout-header")
      refute html =~ ~s(data-testid="portal-layout")
    end

    test "sends Referrer-Policy: no-referrer and leaves the CSP unchanged", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      conn = get(conn, ~p"/i/#{source.key}")

      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "content-security-policy") == [@csp]
    end

    test "unknown key renders the standard 404", %{conn: conn} do
      conn = get(conn, ~p"/i/nope-never-configured")

      assert conn.status == 404
      assert conn.resp_body =~ ~s(data-testid="error-404")
    end

    test "disabled key renders the standard 404", %{conn: conn} do
      source = insert_intake_source(enabled: false)

      conn = get(conn, ~p"/i/#{source.key}")

      assert conn.status == 404
      assert conn.resp_body =~ ~s(data-testid="error-404")
    end
  end

  describe "GET /i/:source_key (passive)" do
    test "renders headline, intro, Q&A, optional email field, and active-flow link", %{
      conn: conn
    } do
      active = insert_intake_source(key: "a-contact", mode: :active)

      source =
        insert_intake_source(
          mode: :passive,
          headline: "Curious about pricing?",
          intro_copy: "Here is what most people ask.",
          questions: [%{"question" => "Is there a trial?", "answer" => "Yes, 30 days."}]
        )

      html = conn |> get(~p"/i/#{source.key}") |> html_response(200)

      assert html =~ ~s(data-testid="intake-passive")
      assert html =~ "Curious about pricing?"
      assert html =~ "Here is what most people ask."
      assert html =~ "Is there a trial?"
      assert html =~ "Yes, 30 days."
      assert html =~ ~s(name="submission[email]")
      assert html =~ ~s(name="submission[notify]")
      assert html =~ ~s(data-testid="intake-active-link")
      assert html =~ ~p"/i/#{active.key}"
    end

    test "omits the active-flow link when no enabled active source exists", %{conn: conn} do
      insert_intake_source(mode: :active, enabled: false)
      source = insert_intake_source(mode: :passive)

      html = conn |> get(~p"/i/#{source.key}") |> html_response(200)

      refute html =~ ~s(data-testid="intake-active-link")
    end

    test "viewing the passive page creates zero database rows", %{conn: conn} do
      source =
        insert_intake_source(
          mode: :passive,
          questions: [%{"question" => "Q?", "answer" => "A."}]
        )

      before = row_counts()
      conn = get(conn, ~p"/i/#{source.key}")

      assert html_response(conn, 200)
      assert row_counts() == before
    end
  end

  describe "POST /i/:source_key" do
    test "anonymous submit creates the conversation and redirects to the conversation URL", %{
      conn: conn
    } do
      source = insert_intake_source(mode: :active)

      conn =
        post(conn, ~p"/i/#{source.key}", %{
          "submission" => %{"body" => "Hello, I want to join the waitlist"}
        })

      assert "/c/" <> token = redirected_to(conn)
      assert byte_size(token) > 40

      conversation = Repo.one!(Conversation)
      assert conversation.source == :public_intake
      assert conversation.intake_source_key == source.key
      assert conversation.organization_id == nil
      assert conversation.contact_id == nil
      assert conversation.subject == "Hello, I want to join the waitlist"
      assert conversation.cached_score > 0

      message = Repo.one!(Message)
      assert message.source == :prospect
      assert message.origin == :public_intake
      assert message.sender_email == nil
      assert message.delivery_status == nil
      refute message.is_internal_note

      prospect = Repo.one!(Prospect)
      assert prospect.conversation_id == conversation.id
      assert prospect.email == nil
    end

    test "the submission appears in the operator queue with intake tag and no-reply badge", %{
      conn: conn
    } do
      source = insert_intake_source(mode: :active)

      post(conn, ~p"/i/#{source.key}", %{
        "submission" => %{"body" => "Queue me up please"}
      })

      operator =
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: "queue-op@example.com", password: "password123"})
        |> Repo.insert!()

      operator_conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, operator.id)

      {:ok, _view, html} = live(operator_conn, ~p"/operator")

      assert html =~ "Queue me up please"
      assert html =~ ~s(data-testid="intake-source-tag")
      assert html =~ ~s(data-testid="no-reply-channel-badge")
    end

    test "sets the signed conversation cookie with the canonical attributes", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      conn =
        post(conn, ~p"/i/#{source.key}", %{"submission" => %{"body" => "Cookie please"}})

      assert "/c/" <> token = redirected_to(conn)
      assert %{} = cookie = conn.resp_cookies["_custyard_conversation"]
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.max_age == 31_536_000
      # Signed, not plaintext: the cookie value is the token wrapped in a
      # signature, never the raw token itself.
      assert cookie.value != token
      assert byte_size(cookie.value) > byte_size(token)
      # :env is :test here; production config flips this on.
      refute cookie[:secure]
    end

    test "the conversation redirect target renders the thread on a fresh session", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      conn =
        post(conn, ~p"/i/#{source.key}", %{"submission" => %{"body" => "See you there"}})

      conversation_path = redirected_to(conn)

      # Cookie-less fresh browser: the URL alone is the credential.
      fresh = Phoenix.ConnTest.build_conn()
      html = fresh |> get(conversation_path) |> html_response(200)

      assert html =~ ~s(data-testid="resume-conversation")
      assert html =~ "See you there"
    end

    test "empty body re-renders the form with a structured error and creates nothing", %{
      conn: conn
    } do
      source = insert_intake_source(mode: :active)

      conn = post(conn, ~p"/i/#{source.key}", %{"submission" => %{"body" => "   \n  "}})
      html = html_response(conn, 422)

      assert html =~ ~s(data-testid="form-error")
      assert html =~ "blank"
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "non-binary body params get a structured 4xx, never a 500", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      for params <- [
            %{"submission" => %{"body" => %{"nested" => "map"}}},
            %{"submission" => %{"body" => ["a", "list"]}},
            %{"submission" => "not-a-map"},
            %{}
          ] do
        conn = post(conn, ~p"/i/#{source.key}", params)
        assert conn.status == 422
        assert conn.resp_body =~ ~s(data-testid="form-error")
      end

      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "oversized body gets a structured 4xx and creates nothing", %{conn: conn} do
      source = insert_intake_source(mode: :active)
      oversized = String.duplicate("a", 100_001)

      conn = post(conn, ~p"/i/#{source.key}", %{"submission" => %{"body" => oversized}})

      assert html_response(conn, 422) =~ "too long"
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "unknown key 404s without creating anything", %{conn: conn} do
      conn = post(conn, ~p"/i/never-was", %{"submission" => %{"body" => "Hi"}})

      assert conn.status == 404
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "passive submission gets the same treatment as active", %{conn: conn} do
      source = insert_intake_source(mode: :passive)

      conn =
        post(conn, ~p"/i/#{source.key}", %{"submission" => %{"body" => "Passive but serious"}})

      assert "/c/" <> _token = redirected_to(conn)

      conversation = Repo.one!(Conversation)
      assert conversation.source == :public_intake
      assert conversation.intake_source_key == source.key
      assert conversation.cached_score > 0
      assert Repo.one!(Prospect).conversation_id == conversation.id
    end

    test "passive optional email flows into capture with the notify choice", %{conn: conn} do
      source = insert_intake_source(mode: :passive)

      conn =
        post(conn, ~p"/i/#{source.key}", %{
          "submission" => %{
            "body" => "Reach me by email",
            "email" => "Prospect@Example.com",
            "notify" => "true"
          }
        })

      assert "/c/" <> _token = redirected_to(conn)

      prospect = Repo.one!(Prospect)
      assert prospect.email == "prospect@example.com"
      assert prospect.notify_on_reply
      assert prospect.email_captured_at
    end

    test "a capture failure does not lose the submission", %{conn: conn} do
      source = insert_intake_source(mode: :passive)

      conn =
        post(conn, ~p"/i/#{source.key}", %{
          "submission" => %{"body" => "Bad email attached", "email" => "not-an-email"}
        })

      assert "/c/" <> _token = redirected_to(conn)

      conversation = Repo.one!(Conversation)
      assert conversation.subject == "Bad email attached"

      prospect = Repo.one!(Prospect)
      assert prospect.email == nil
    end

    test "a burst past :intake_post gets structured 429s and creates no new rows", %{conn: _} do
      put_buckets(intake_post: [limit: 2, window_ms: 60_000])
      source = insert_intake_source(mode: :active)

      for n <- 1..2 do
        conn =
          Phoenix.ConnTest.build_conn()
          |> post(~p"/i/#{source.key}", %{"submission" => %{"body" => "Burst #{n}"}})

        assert "/c/" <> _token = redirected_to(conn)
      end

      assert Repo.aggregate(Conversation, :count) == 2

      denied =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/i/#{source.key}", %{"submission" => %{"body" => "Burst 3"}})

      assert denied.status == 429
      assert denied.resp_body =~ ~s(data-testid="error-429")
      assert [_retry] = get_resp_header(denied, "retry-after")
      assert Repo.aggregate(Conversation, :count) == 2
    end
  end

  describe "conversation banner on intake pages" do
    test "a verifying cookie renders the banner link and no conversation content", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      conn =
        post(conn, ~p"/i/#{source.key}", %{
          "submission" => %{"body" => "Banner secret content"}
        })

      assert "/c/" <> token = redirected_to(conn)

      # Same conn: Phoenix.ConnTest recycles response cookies automatically.
      conn = get(conn, ~p"/i/#{source.key}")
      html = html_response(conn, 200)

      assert html =~ ~s(data-testid="intake-resume-banner")
      assert html =~ ~p"/c/#{token}"
      refute html =~ "Banner secret content"
    end

    test "an unsigned or garbage cookie renders no banner", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      conn =
        conn
        |> put_req_cookie("_custyard_conversation", "garbage-value")
        |> get(~p"/i/#{source.key}")

      refute html_response(conn, 200) =~ ~s(data-testid="intake-resume-banner")
    end

    test "a revoked prospect renders no banner", %{conn: conn} do
      source = insert_intake_source(mode: :active)

      conn =
        post(conn, ~p"/i/#{source.key}", %{"submission" => %{"body" => "Revoke me soon"}})

      conversation = Repo.one!(Conversation)
      {:ok, _prospect} = Custyard.Intake.revoke_conversation_access(conversation)

      conn = get(conn, ~p"/i/#{source.key}")

      refute html_response(conn, 200) =~ ~s(data-testid="intake-resume-banner")
    end
  end

  describe "GET /c/:token over HTTP" do
    test "refreshes the conversation cookie on a valid token", %{conn: _} do
      source = insert_intake_source(mode: :active)

      {:ok, %{access_token: token}} =
        Custyard.Intake.create_intake_conversation(source.key, "Refresh my cookie")

      conn = Phoenix.ConnTest.build_conn() |> get(~p"/c/#{token}")

      assert html_response(conn, 200) =~ ~s(data-testid="resume-conversation")
      assert %{} = cookie = conn.resp_cookies["_custyard_conversation"]
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.max_age == 31_536_000
      assert cookie.value != token
    end

    test "an invalid token redirects to the uniform page and sets no cookie", %{conn: conn} do
      conn = get(conn, ~p"/c/definitely-not-a-token")

      assert redirected_to(conn) == "/c/unavailable"
      refute Map.has_key?(conn.resp_cookies, "_custyard_conversation")
    end

    test "a rate-limited client gets no cookie refresh even for a valid token", %{conn: _} do
      put_buckets(conversation_mount: [limit: 1, window_ms: 60_000])
      source = insert_intake_source(mode: :active)

      {:ok, %{access_token: token}} =
        Custyard.Intake.create_intake_conversation(source.key, "Probe target")

      # First GET: the cookie plug's non-counting peek allows, the mount
      # check consumes the whole budget.
      first = Phoenix.ConnTest.build_conn() |> get(~p"/c/#{token}")
      assert html_response(first, 200)
      assert Map.has_key?(first.resp_cookies, "_custyard_conversation")

      # Over the limit, valid and invalid tokens are indistinguishable:
      # the peek denies BEFORE any token lookup, so the 302 carries no
      # Set-Cookie — presence of the refresh is not a validity oracle and
      # the lookup itself stays inside the :conversation_mount budget.
      denied_valid = Phoenix.ConnTest.build_conn() |> get(~p"/c/#{token}")
      assert redirected_to(denied_valid) == "/c/unavailable"
      refute Map.has_key?(denied_valid.resp_cookies, "_custyard_conversation")

      denied_invalid = Phoenix.ConnTest.build_conn() |> get(~p"/c/definitely-not-a-token")
      assert redirected_to(denied_invalid) == "/c/unavailable"
      refute Map.has_key?(denied_invalid.resp_cookies, "_custyard_conversation")
    end

    test "the unavailable page renders with the no-referrer policy", %{conn: conn} do
      conn = get(conn, "/c/unavailable")

      assert html_response(conn, 200) =~ "Conversation unavailable"
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "content-security-policy") == [@csp]
    end
  end

  describe "custom domains (CustomDomain plug unchanged)" do
    test "intake and conversation paths on a customer domain rewrite into the portal and 404" do
      insert_organization(custom_domain: "support.acme-custyard-test.com")
      source = insert_intake_source(mode: :active)

      {:ok, %{access_token: token}} =
        Custyard.Intake.create_intake_conversation(source.key, "Not on this host")

      for path <- ["/i/#{source.key}", "/c/#{token}"] do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, "support.acme-custyard-test.com")
          |> get(path)

        # The CustomDomain plug rewrote the path into the portal scope,
        # where it matches no route: intake surfaces exist on the
        # application host only, and no cookie is issued.
        assert conn.status == 404
        assert String.starts_with?(conn.request_path, "/p/")
        refute Map.has_key?(conn.resp_cookies, "_custyard_conversation")
      end
    end
  end

  test "prospect message ordering sanity: queue message count reflects submissions" do
    # Guards against accidental double-insert from the capture path.
    source = insert_intake_source(mode: :passive)

    Phoenix.ConnTest.build_conn()
    |> post(~p"/i/#{source.key}", %{
      "submission" => %{"body" => "One message only", "email" => "solo@example.com"}
    })

    conversation = Repo.one!(Conversation)

    count =
      Repo.one(from m in Message, where: m.conversation_id == ^conversation.id, select: count())

    assert count == 1
  end
end

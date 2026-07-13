defmodule Custyard.SentryTest do
  @moduledoc """
  Tests for the Sentry data-scrubbing hooks.

  The security guarantee rests on two wiring contracts that fail *silently* if
  wrong, so these are exercised empirically rather than by regex alone:

    * `before_send/1` is invoked by Sentry as `mod.fun(event)` at arity 1 — the
      "before_send/1" describe block calls it exactly that way.
    * `Sentry.PlugContext` invokes the `:url_scrubber` with the conn and stores
      the returned string — the "PlugContext wiring" block runs the real plug
      and reads the stored context back.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

  alias Custyard.Sentry, as: Scrub
  alias Sentry.Interfaces.{Message, Request}

  @redacted "[REDACTED]"

  # Sentry.Event enforces :event_id and :timestamp.
  defp event(fields) do
    struct!(
      %Sentry.Event{event_id: "test-event-id", timestamp: "2026-07-12T00:00:00Z"},
      fields
    )
  end

  describe "scrub_path/1 redacts bearer tokens in the path" do
    test "conversation token" do
      assert Scrub.scrub_path("/c/abc123token") == "/c/#{@redacted}"
    end

    test "claim token, preserving the trailing /confirm segment" do
      assert Scrub.scrub_path("/claim/tok987") == "/claim/#{@redacted}"
      assert Scrub.scrub_path("/claim/tok987/confirm") == "/claim/#{@redacted}/confirm"
    end

    test "operator magic-link verify token" do
      assert Scrub.scrub_path("/operator/login/verify/magiclink") ==
               "/operator/login/verify/#{@redacted}"
    end

    test "routed-webhook callback token" do
      assert Scrub.scrub_path("/api/webhook/route/cbtoken") == "/api/webhook/route/#{@redacted}"
    end

    test "portal org token, preserving trailing segments" do
      assert Scrub.scrub_path("/p/orgtoken") == "/p/#{@redacted}"
      assert Scrub.scrub_path("/p/orgtoken/request/5") == "/p/#{@redacted}/request/5"
    end

    test "leaves non-sensitive paths untouched" do
      # /i/:source_key is an operator-published identifier, not a credential.
      for path <- ["/", "/i/eu-otshosted", "/operator", "/operator/projects", "/api/health"] do
        assert Scrub.scrub_path(path) == path
      end
    end

    test "redacts a token embedded in free-form text (crash messages)" do
      msg = "GenServer terminating while handling GET /c/leakytoken from client"
      assert Scrub.scrub_path(msg) =~ "/c/#{@redacted}"
      refute Scrub.scrub_path(msg) =~ "leakytoken"
    end

    test "nil passes through" do
      assert Scrub.scrub_path(nil) == nil
    end
  end

  describe "scrub_query/1 redacts sensitive param values" do
    test "redacts sensitive params, keeps names and other values" do
      assert Scrub.scrub_query("token=abc&keep=1") == "token=#{@redacted}&keep=1"

      assert Scrub.scrub_query("secret=s&key=k&passphrase=p") ==
               "secret=#{@redacted}&key=#{@redacted}&passphrase=#{@redacted}"
    end

    test "matches param names case-insensitively" do
      assert Scrub.scrub_query("Token=abc") == "Token=#{@redacted}"
    end

    test "redacts the dev impersonation param ?as=" do
      assert Scrub.scrub_query("as=contact_42") == "as=#{@redacted}"
    end

    test "nil and empty pass through" do
      assert Scrub.scrub_query(nil) == nil
      assert Scrub.scrub_query("") == ""
    end
  end

  describe "scrub_text/1 protects the crash-report path (bare keyed values)" do
    test "redacts a token that appears as an inspected atom-keyed value" do
      # This is the real shape from a crashed LiveView's inspected socket state.
      text = ~s|assigns: %{access_token: "PmpCZyxu-secret", __changed__: %{}}|
      result = Scrub.scrub_text(text)

      refute result =~ "PmpCZyxu-secret"
      assert result =~ ~s|access_token: "#{@redacted}"|
    end

    test "redacts a token in string-keyed map (params) form" do
      assert Scrub.scrub_text(~s|%{"token" => "abc123"}|) =~ ~s|"token" => "#{@redacted}"|
      refute Scrub.scrub_text(~s|%{"token" => "abc123"}|) =~ "abc123"
    end

    test "redacts a prospect email keyed value" do
      assert Scrub.scrub_text(~s|email: "prospect@example.com"|) =~ ~s|email: "#{@redacted}"|
    end

    test "redacts the escaped-quote form (nested inspect in a crash report)" do
      # A crash report nests an already-inspected socket, so the outer inspect
      # renders the value with escaped quotes: access_token: \"...\"
      text = ~S|reason: "assigns: %{access_token: \"escaped-secret\"}"|
      result = Scrub.scrub_text(text)

      refute result =~ "escaped-secret"
      assert result =~ "[REDACTED]"
    end

    test "preserves access_token_hash (a non-reversible correlation id)" do
      text = ~s|access_token_hash: "DdxiQ9lq_hashvalue"|
      assert Scrub.scrub_text(text) == text
    end

    test "redacts a full-URL path token embedded in text (lookbehind bug fix)" do
      # The char before /c/ is a word char here; the old lookbehind missed it.
      text = "raise while handling https://custyard.fly.dev/c/urltoken now"
      assert Scrub.scrub_text(text) =~ "/c/#{@redacted}"
      refute Scrub.scrub_text(text) =~ "urltoken"
    end

    test "nil passes through" do
      assert Scrub.scrub_text(nil) == nil
    end
  end

  describe "scrub_url/1 scrubs path and query together" do
    test "redacts both a path token and a query token" do
      url = "https://custyard.fly.dev/c/tok?token=abc&keep=1"

      assert Scrub.scrub_url(url) ==
               "https://custyard.fly.dev/c/#{@redacted}?token=#{@redacted}&keep=1"
    end

    test "leaves a benign URL untouched" do
      url = "https://custyard.fly.dev/operator/projects?page=2"
      assert Scrub.scrub_url(url) == url
    end

    test "nil and empty pass through" do
      assert Scrub.scrub_url(nil) == nil
      assert Scrub.scrub_url("") == ""
    end
  end

  describe "scrub_conn_url/1 — the PlugContext :url_scrubber contract" do
    test "returns a full URL string with the path token redacted" do
      result = Scrub.scrub_conn_url(conn(:get, "/c/secrettoken?token=abc&keep=1"))

      assert is_binary(result)
      assert result =~ "/c/#{@redacted}"
      assert result =~ "token=#{@redacted}"
      assert result =~ "keep=1"
      refute result =~ "secrettoken"
    end
  end

  describe "scrub_conn_body/1 sends no request params" do
    test "always returns an empty map" do
      assert Scrub.scrub_conn_body(conn(:post, "/i/src", %{"email" => "a@b.co"})) == %{}
    end
  end

  describe "before_send/1 — invoked exactly as Sentry invokes it (arity 1)" do
    test "scrubs the request url and query_string" do
      event =
        event(
          request: %Request{
            url: "https://custyard.fly.dev/operator/login/verify/magiclink?token=abc",
            query_string: "token=abc&keep=1"
          }
        )

      scrubbed = Scrub.before_send(event)

      assert scrubbed.request.url =~ "/operator/login/verify/#{@redacted}"
      refute scrubbed.request.url =~ "magiclink"
      assert scrubbed.request.query_string == "token=#{@redacted}&keep=1"
    end

    test "scrubs the access token from an inspected-crash-state message + extra" do
      # Shape taken from a real ConversationLive crash: the token appears as a
      # bare keyed value in both the message and extra.crash_reason.
      state = ~s|#Socket<assigns: %{access_token: "leaktok", branding: nil}>|

      event =
        event(
          message: %Message{formatted: state, message: state},
          extra: %{crash_reason: "** (exit) #{state}", other: "keep me"}
        )

      scrubbed = Scrub.before_send(event)

      refute scrubbed.message.formatted =~ "leaktok"
      refute scrubbed.message.message =~ "leaktok"
      refute scrubbed.extra.crash_reason =~ "leaktok"
      assert scrubbed.extra.crash_reason =~ ~s|access_token: "#{@redacted}"|
      # Non-sensitive extra is preserved for debugging.
      assert scrubbed.extra.other == "keep me"
    end

    test "redacts a whole extra value stored under a sensitive key" do
      event = event(extra: %{token: "rawsecret", note: "fine"})
      scrubbed = Scrub.before_send(event)

      assert scrubbed.extra.token == @redacted
      assert scrubbed.extra.note == "fine"
    end

    test "drops unmatched-route 404 noise" do
      event = event(original_exception: %Phoenix.Router.NoRouteError{})
      assert Scrub.before_send(event) == nil
    end

    test "keeps a normal event" do
      event = event(request: %Request{url: "https://custyard.fly.dev/operator"})
      assert %Sentry.Event{} = Scrub.before_send(event)
    end

    test "fails closed: redacts rather than leaks if scrubbing raises" do
      # A non-binary url forces scrub_url/1 to raise; the rescue must redact,
      # never pass the raw value through, and still return a reportable event.
      event = event(request: %Request{url: {:not, "a string"}})

      scrubbed = Scrub.before_send(event)

      assert %Sentry.Event{} = scrubbed
      assert scrubbed.request.url == "[SCRUBBING_FAILED]"
    end
  end

  describe "PlugContext wiring — the scrubber is actually called and stored" do
    test "a real request through Sentry.PlugContext stores a redacted url" do
      opts =
        Sentry.PlugContext.init(
          url_scrubber: {Custyard.Sentry, :scrub_conn_url},
          body_scrubber: {Custyard.Sentry, :scrub_conn_body}
        )

      Sentry.PlugContext.call(conn(:get, "/c/secrettoken?token=abc&keep=1"), opts)

      request = Sentry.Context.get_all().request

      assert request.url =~ "/c/#{@redacted}"
      assert request.url =~ "token=#{@redacted}"
      refute request.url =~ "secrettoken"
    end
  end

  describe "config safety" do
    test "before_send is wired to the scrubber" do
      assert Application.get_env(:sentry, :before_send) == {Custyard.Sentry, :before_send}
    end

    test "the test suite can never reach a live Sentry instance" do
      assert Application.get_env(:sentry, :dsn) == nil
    end
  end
end

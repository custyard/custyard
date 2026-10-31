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

    test "preserves a valueless (flag-style) param as just the key" do
      assert Scrub.scrub_query("debug&token=x&page=2") == "debug&token=#{@redacted}&page=2"
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

    test "redacts a channel's captured forwarding confirmation" do
      # The setup wizard holds the channel struct in assigns; a crash there
      # inspects the code and the one-click confirmation link.
      text =
        ~s|%Custyard.InboundChannel{ingress_token: "abcd1234abcd1234abcd", | <>
          ~s|verification_code: "123456789", | <>
          ~s|verification_link: "https://mail.google.com/mail/vf-%5BANGjdJ...", state: :pending}|

      result = Scrub.scrub_text(text)

      refute result =~ "abcd1234abcd1234abcd"
      refute result =~ "123456789"
      refute result =~ "ANGjdJ"
      assert result =~ ~s|verification_code: "#{@redacted}"|
      assert result =~ ~s|verification_link: "#{@redacted}"|
      assert result =~ "state: :pending"
    end

    test "redacts the confirmation fields in string-keyed form" do
      text = ~s|%{"verification_code" => "987", "verification_link" => "https://x.proton.me/y"}|
      result = Scrub.scrub_text(text)

      refute result =~ "987"
      refute result =~ "x.proton.me"
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

  describe "scrub_text/1 redacts URI userinfo" do
    test "redacts user and password, keeping scheme, host and vhost" do
      text = "connect failed: amqps://custyard:s3cret@broker.example:5671/ots-vhost"

      assert Scrub.scrub_text(text) ==
               "connect failed: amqps://#{@redacted}@broker.example:5671/ots-vhost"
    end

    test "redacts the amqp_client parse error shape (an inspected charlist)" do
      # :amqp_uri.parse/1 returns {:error, {Reason, Uri}} with the whole URI.
      text =
        inspect({:error, {{:port_out_of_range, 99_999}, ~c"amqp://user:pa'ss,w@localhost:99999"}})

      result = Scrub.scrub_text(text)

      refute result =~ "pa'ss"
      refute result =~ "user:"
      assert result =~ ~s|~c"amqp://#{@redacted}@localhost:99999"|
    end

    test "stops at the closing quote of an inspected value" do
      text = ~s|url: "amqp://u:p@host", note: "mail me at a@b.example"|

      assert Scrub.scrub_text(text) ==
               ~s|url: "amqp://#{@redacted}@host", note: "mail me at a@b.example"|
    end

    test "redacts a username-only userinfo and leaves plain URLs alone" do
      assert Scrub.scrub_text("amqp://guest@localhost") == "amqp://#{@redacted}@localhost"

      assert Scrub.scrub_text("https://custyard.fly.dev/health") ==
               "https://custyard.fly.dev/health"
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

  describe "before_send/1 — a complete event minimization boundary" do
    test "retains only a known method and route template from the request" do
      scrubbed =
        event(
          request: %Request{
            method: "POST",
            url:
              "https://customer.example/operator/login/verify/magiclink?token=abc&name=private",
            query_string: "token=abc&keep=private",
            data: %{body: "customer message"},
            headers: %{"authorization" => "secret", "x-custom" => "private"},
            cookies: %{session: "secret"},
            env: %{remote_addr: "192.0.2.1"}
          }
        )
        |> Scrub.before_send()

      assert scrubbed.request == %Request{
               method: "POST",
               url: "/operator/login/verify/[REDACTED]"
             }
    end

    test "unknown path segments and query keys never become diagnostics" do
      scrubbed =
        event(request: %Request{url: "https://private.example/patient-name?diagnosis=private"})
        |> Scrub.before_send()

      assert scrubbed.request.url == "/[OTHER]"
      refute inspect(scrubbed) =~ "patient-name"
      refute inspect(scrubbed) =~ "private.example"
    end

    test "rendered messages and unstructured extras are omitted, including unlabelled content" do
      private = "A patient's unlabelled medical history"

      scrubbed =
        event(
          message: %Message{formatted: private, message: private, params: [private]},
          extra: %{
            crash_reason: private,
            note: private,
            operator_id: 7,
            tenant_id: 9,
            request_id: "req_12345678901234567890",
            operation_id: "op_12345678901234567890"
          }
        )
        |> Scrub.before_send()

      assert scrubbed.message == %Message{
               formatted: "application_error",
               message: "application_error",
               params: []
             }

      assert scrubbed.extra.operator_id == 7
      assert scrubbed.extra.tenant_id == 9
      assert scrubbed.extra.request_id == "req_12345678901234567890"
      assert scrubbed.extra.operation_id == "op_12345678901234567890"
      refute Map.has_key?(scrubbed.extra, :crash_reason)
      refute inspect(scrubbed, limit: :infinity) =~ private
    end

    test "every event compartment is minimized, including private SDK fields" do
      private = "PRIVATE-CUSTOMER-CONTENT-CANARY"
      stacktrace = private_stacktrace(private)

      scrubbed =
        event(
          event_id: private,
          timestamp: private,
          environment: private,
          release: private,
          dist: private,
          platform: private,
          logger: private,
          server_name: private,
          transaction: private,
          culprit: private,
          source: private,
          modules: %{private => private},
          user: %{email: private, id: private, custom: private},
          contexts: %{private => %{private => private}},
          breadcrumbs: [
            %Sentry.Interfaces.Breadcrumb{
              type: private,
              category: private,
              message: private,
              data: %{private => private},
              timestamp: private,
              level: private
            }
          ],
          fingerprint: [private],
          tags: %{private => private, :operator_id => 12},
          extra: %{private => private, :operator_id => 12},
          request: %Request{
            url: "https://#{private}/i/#{private}?#{private}=#{private}",
            method: private,
            query_string: private,
            data: %{private => private},
            cookies: private,
            headers: %{private => private},
            env: %{private => private}
          },
          message: %Message{formatted: private, message: private, params: [private]},
          exception: [
            %Sentry.Interfaces.Exception{
              type: "RuntimeError",
              value: private,
              module: private,
              stacktrace: stacktrace,
              mechanism: %Sentry.Interfaces.Exception.Mechanism{
                type: private,
                data: %{private => private},
                meta: %{private => private},
                help_link: private,
                handled: true
              }
            }
          ],
          threads: [
            %Sentry.Interfaces.Thread{
              id: private,
              name: private,
              state: %{private => private},
              held_locks: [private],
              stacktrace: stacktrace,
              crashed: true
            }
          ],
          sdk: %Sentry.Interfaces.SDK{name: private, version: private},
          attachments: [%{filename: private, data: private}],
          original_exception: RuntimeError.exception(private),
          integration_meta: %{private => private}
        )
        |> Scrub.before_send()

      refute inspect(scrubbed, limit: :infinity, printable_limit: :infinity) =~ private
      assert scrubbed.environment == "test"
      assert scrubbed.extra == %{operator_id: 12}
      assert scrubbed.tags == %{operator_id: 12}
      assert scrubbed.attachments == []
      assert scrubbed.original_exception == nil
      assert scrubbed.user == %{}
      assert scrubbed.breadcrumbs == []
      assert scrubbed.contexts == nil
      assert scrubbed.request == %Request{url: "/i/[REDACTED]"}
      assert [%{type: "RuntimeError", value: @redacted} = exception] = scrubbed.exception
      assert exception.module == nil
      assert exception.mechanism == %Sentry.Interfaces.Exception.Mechanism{handled: true}
      assert [%{module: __MODULE__, lineno: 123} = frame] = exception.stacktrace.frames
      assert frame.function == Exception.format_mfa(__MODULE__, :__info__, 1)
      assert frame.filename == "sentry_test.exs"
      assert frame.vars == nil
      assert frame.context_line == nil
      assert frame.pre_context == []
      assert frame.post_context == []
      assert [%{id: 0, crashed: true, state: nil, held_locks: nil}] = scrubbed.threads
      assert Regex.match?(~r/\A[0-9a-f]{32}\z/, scrubbed.event_id)
      assert {:ok, _, _} = DateTime.from_iso8601(scrubbed.timestamp)
    end

    test "a failed minimization rebuilds a minimal event without any original compartment" do
      private = "SCRUB-FAILURE-PRIVATE-CANARY"

      # Struct-tagged terms can arrive from third-party context integrations.
      # This deliberately malformed interface raises when its missing type is read.
      malformed_exception = %{__struct__: Sentry.Interfaces.Exception, value: private}

      scrubbed =
        event(
          exception: [malformed_exception],
          request: %Request{data: private, headers: %{private => private}},
          extra: %{private => private},
          tags: %{private => private},
          user: %{email: private},
          contexts: %{private => private},
          fingerprint: [private],
          transaction: private,
          attachments: [%{data: private}],
          original_exception: RuntimeError.exception(private)
        )
        |> Scrub.before_send()

      assert %Sentry.Event{} = scrubbed
      assert scrubbed.message.formatted == "sentry_scrubbing_failed"
      assert scrubbed.request == %Request{}
      assert scrubbed.exception == []
      assert scrubbed.extra == %{}
      assert scrubbed.attachments == []
      assert scrubbed.original_exception == nil
      refute inspect(scrubbed, limit: :infinity, printable_limit: :infinity) =~ private
    end

    test "unknown exception and frame strings are never accepted as code identity" do
      private = "CustomerDataCanary"

      scrubbed =
        event(
          exception: [
            %Sentry.Interfaces.Exception{
              type: private,
              value: private,
              stacktrace: %Sentry.Interfaces.Stacktrace{
                frames: [
                  %Sentry.Interfaces.Stacktrace.Frame{
                    module: private,
                    function: private,
                    filename: private,
                    vars: %{data: private}
                  }
                ]
              }
            }
          ]
        )
        |> Scrub.before_send()

      assert [%{type: "UnknownError", stacktrace: %{frames: []}}] = scrubbed.exception
      refute inspect(scrubbed) =~ private
    end

    test "logger events retain approved event, origin and correlation with distinct grouping" do
      origin = {__MODULE__, :__info__, 1}
      origin_string = "#{__MODULE__}.__info__/1"

      atom_keys =
        event(
          message: %Message{formatted: "PRIVATE-RENDERED-CONTENT"},
          extra: %{
            logger_metadata: %{
              custyard_event: :outbound_status_update_failed,
              mfa: origin,
              error_type: RuntimeError,
              request_id: "req_12345678901234567890",
              operation_id: "op_12345678901234567890",
              message_id: 17,
              private: "PRIVATE-RENDERED-CONTENT"
            }
          }
        )
        |> Scrub.before_send()

      string_keys =
        event(
          message: %Message{formatted: "PRIVATE-RENDERED-CONTENT"},
          extra: %{
            "logger_metadata" => %{
              "custyard_event" => "webhook_purpose_failed",
              "mfa" => origin_string,
              "error_type" => "Elixir.RuntimeError",
              "request_id" => "req_12345678901234567890"
            }
          }
        )
        |> Scrub.before_send()

      assert atom_keys.message.formatted == "outbound_status_update_failed"
      assert atom_keys.extra.event == "outbound_status_update_failed"
      assert atom_keys.extra.origin == origin_string
      assert atom_keys.extra.error_type == "Elixir.RuntimeError"
      assert atom_keys.extra.message_id == 17
      assert atom_keys.extra.request_id == "req_12345678901234567890"
      assert atom_keys.extra.operation_id == "op_12345678901234567890"
      refute Map.has_key?(atom_keys.extra, :logger_metadata)
      assert atom_keys.tags == %{event: "outbound_status_update_failed", origin: origin_string}

      assert atom_keys.fingerprint == [
               "custyard",
               "outbound_status_update_failed",
               "Elixir.RuntimeError",
               origin_string
             ]

      assert string_keys.message.formatted == "webhook_purpose_failed"
      assert string_keys.extra.origin == origin_string
      assert string_keys.extra.request_id == "req_12345678901234567890"
      assert atom_keys.fingerprint != string_keys.fingerprint
      refute inspect(atom_keys, limit: :infinity) =~ "PRIVATE-RENDERED-CONTENT"
      refute inspect(string_keys, limit: :infinity) =~ "PRIVATE-RENDERED-CONTENT"
    end

    test "spoofed event, message and code identity are discarded instead of fingerprinted" do
      private = "PRIVATE-SPOOFED-CONTENT"

      scrubbed =
        event(
          message: %Message{formatted: "operator_login_requested\n#{private}"},
          extra: %{
            logger_metadata: %{
              custyard_event: private,
              mfa: {private, private, private},
              origin: private
            },
            event: private,
            origin: private
          },
          tags: %{event: private, origin: private},
          fingerprint: [private]
        )
        |> Scrub.before_send()

      assert scrubbed.message.formatted == "application_error"
      assert scrubbed.extra == %{}
      assert scrubbed.tags == %{}

      assert scrubbed.fingerprint == [
               "custyard",
               "application_error",
               "UnknownError",
               "unknown_origin"
             ]

      refute inspect(scrubbed, limit: :infinity) =~ private
    end

    test "safe code location keeps independent exception sites grouped separately" do
      first = private_stacktrace("private")
      second = put_in(first.frames, [%{hd(first.frames) | lineno: 124}])

      make_event = fn stack ->
        event(
          exception: [
            %Sentry.Interfaces.Exception{
              type: "RuntimeError",
              value: "private",
              stacktrace: stack
            }
          ]
        )
        |> Scrub.before_send()
      end

      assert make_event.(first).fingerprint != make_event.(second).fingerprint
    end

    test "invalid UTF-8, multiline values and oversized content cannot escape" do
      private = <<255>> <> "\r\nPRIVATE-CUSTOMER-CONTENT" <> String.duplicate("x", 20_000)

      scrubbed =
        event(
          message: %Message{formatted: private, message: private, params: [private]},
          request: %Request{url: private, method: private, data: private},
          extra: %{body: private, error: RuntimeError.exception(private)}
        )
        |> Scrub.before_send()

      assert scrubbed.message.formatted == "application_error"
      assert scrubbed.request.url == nil
      refute inspect(scrubbed, limit: :infinity) =~ "PRIVATE-CUSTOMER-CONTENT"
      assert String.valid?(scrubbed.message.formatted)
    end

    test "drops unmatched-route 404 noise and unexpected callback values" do
      assert event(original_exception: %Phoenix.Router.NoRouteError{}) |> Scrub.before_send() ==
               nil

      assert Scrub.before_send(%{message: "private"}) == nil
      assert Scrub.before_send(nil) == nil
    end

    test "keeps a normal exception event and bounds frame collection" do
      frame = hd(private_stacktrace("private").frames)

      scrubbed =
        event(
          exception:
            for _ <- 1..12 do
              %Sentry.Interfaces.Exception{
                type: "RuntimeError",
                value: "private",
                stacktrace: %Sentry.Interfaces.Stacktrace{frames: List.duplicate(frame, 120)}
              }
            end
        )
        |> Scrub.before_send()

      assert length(scrubbed.exception) == 8
      assert Enum.all?(scrubbed.exception, &(length(&1.stacktrace.frames) == 100))
    end
  end

  defp private_stacktrace(private) do
    %Sentry.Interfaces.Stacktrace{
      frames: [
        %Sentry.Interfaces.Stacktrace.Frame{
          module: __MODULE__,
          function: Exception.format_mfa(__MODULE__, :__info__, 1),
          filename: private,
          lineno: 123,
          colno: 4,
          in_app: true,
          vars: %{customer: private},
          context_line: private,
          pre_context: [private],
          post_context: [private]
        }
      ]
    }
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

  describe "token_path?/1" do
    test "recognizes every path that carries a bearer credential" do
      assert Scrub.token_path?("/c/abc123")
      assert Scrub.token_path?("/claim/abc123/confirm")
      assert Scrub.token_path?("/operator/login/verify/abc123")
      assert Scrub.token_path?("/api/webhook/route/abc123")
      assert Scrub.token_path?("/p/orgtoken/request/5")

      refute Scrub.token_path?("/")
      refute Scrub.token_path?("/operator/login")
      refute Scrub.token_path?("/i/quote")
      refute Scrub.token_path?(nil)
    end
  end
end

defmodule Custyard.SentryEnvironmentTest do
  # Environment labels are application configuration, so isolate these changes
  # from tests that depend on the normal test label.
  use ExUnit.Case, async: false

  setup do
    sentry_environment = Application.fetch_env(:sentry, :environment_name)
    allowed_environments = Application.fetch_env(:custyard, :log_environments)
    runtime_environment = Application.fetch_env(:custyard, :env)

    # Other controller tests deliberately remove their runtime override. Set
    # this test's fallback explicitly instead of relying on suite order.
    Application.put_env(:custyard, :env, :test)

    on_exit(fn ->
      restore(:sentry, :environment_name, sentry_environment)
      restore(:custyard, :log_environments, allowed_environments)
      restore(:custyard, :env, runtime_environment)
    end)

    :ok
  end

  test "reviewed deployment labels preserve staging and deployment identity" do
    for label <- ["staging", :staging, "custyard-eu-prod", :test] do
      Application.put_env(:sentry, :environment_name, label)
      assert minimized_environment() == to_string(label)
    end
  end

  test "unknown and malformed labels fall back to the application environment" do
    for label <- ["PRIVATE-DEPLOYMENT-CANARY", <<255>>, %{secret: "private"}, nil] do
      Application.put_env(:sentry, :environment_name, label)
      assert minimized_environment() == "test"
    end
  end

  test "a deployment label must be explicitly admitted by the reviewed configuration" do
    Application.put_env(:sentry, :environment_name, "staging")
    Application.put_env(:custyard, :log_environments, ["test"])
    assert minimized_environment() == "test"

    Application.put_env(:custyard, :log_environments, :invalid)
    assert minimized_environment() == "test"
  end

  test "fallback uses the explicit runtime environment and is unknown when unset" do
    Application.put_env(:sentry, :environment_name, "UNREVIEWED-DEPLOYMENT")

    for environment <- [:prod, :dev, :test] do
      Application.put_env(:custyard, :env, environment)
      assert minimized_environment() == Atom.to_string(environment)
    end

    Application.delete_env(:custyard, :env)
    assert minimized_environment() == "unknown"
  end

  defp minimized_environment do
    %Sentry.Event{event_id: String.duplicate("a", 32), timestamp: "2026-10-31T00:00:00Z"}
    |> Custyard.Sentry.before_send()
    |> Map.fetch!(:environment)
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end

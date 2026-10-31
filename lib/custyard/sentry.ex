defmodule Custyard.Sentry do
  @moduledoc """
  Sentry data-scrubbing hooks for Custyard.

  Custyard's public surfaces carry bearer credentials **in the URL path**, not
  in headers — a conversation token (`/c/:token`), a slug-claim token
  (`/claim/:token`), an operator magic-link token
  (`/operator/login/verify/:token`), a routed-webhook callback token
  (`/api/webhook/route/:token`) and the unguessable portal org token
  (`/p/:org_token/...`). Sentry's built-in `Sentry.PlugContext` url scrubber
  only redacts *query* parameters, so without this module those path tokens
  would ship to the error tracker verbatim and become a credential leak in the
  one place operators look when something breaks.

  This module is the single source of truth for that redaction. It is wired in
  two complementary places (defence in depth), both delegating to the same
  `scrub_url/1` / `scrub_path/1` core:

    * `scrub_conn_url/1` — the `:url_scrubber` for `Sentry.PlugContext`, so an
      HTTP request's URL is redacted *before* it is stored on the event.
    * `before_send/1` — the global `:before_send` callback (`config :sentry`),
      the fail-closed choke point every event passes through regardless of
      source (Plug capture, `Sentry.LoggerHandler` process/LiveView crashes,
      or manual `Sentry.capture_*`).

  The send boundary rebuilds an event from a small allowlist rather than trying
  to recognize every possible piece of personal data in an arbitrary message.
  Rendered exception messages, socket state, request payloads, headers, cookies,
  breadcrumbs, user profiles, source context and attachments are omitted. Loaded
  exception classes, code locations and approved operational metadata remain.

  If minimization fails, a new, fixed diagnostic event is returned. None of the
  original event's compartments survive that failure path.
  """

  @redacted "[REDACTED]"
  @scrub_failed "[SCRUBBING_FAILED]"

  # Exact key/param names (compared case-insensitively) whose *values* must
  # never reach Sentry. Used for query-parameter names AND for structured map
  # keys in :extra. Covers the path-token names when they appear as params/keys,
  # generic secret-bearing names, and the dev-only `?as=<contact_id>`
  # impersonation param.
  # `attachments` holds the provider's signed download URLs while a delivery is
  # in flight (spec-inbound-channels D9: never logged, never stored).
  # `imap_password` is an IMAP channel's password in the wizard's event params;
  # `imap_password_ciphertext` is its stored form (D8).
  @sensitive_keys ~w(access_token org_token callback_token token key credential secret passphrase password email as verification_code verification_link attachments imap_password imap_password_ciphertext)

  # Path patterns. Each redacts the single credential segment that follows a
  # known prefix, leaving the prefix (and any trailing segments) intact for
  # debugging — e.g. `/claim/<tok>/confirm` -> `/claim/[REDACTED]/confirm`. The
  # `[^/?#\s]+` credential class stops at the next path separator, query/fragment
  # marker, or whitespace, so these work both on a bare path (from `scrub_url`)
  # and on a full URL embedded in free-form text such as a crash message.
  @path_patterns [
    ~r{(/c/)[^/?#\s]+},
    ~r{(/claim/)[^/?#\s]+},
    ~r{(/operator/login/verify/)[^/?#\s]+},
    ~r{(/api/webhook/route/)[^/?#\s]+},
    ~r{(/p/)[^/?#\s]+}
  ]

  # Crash reports (Sentry.LoggerHandler) `inspect/1` the crashed process's state
  # into the event message and `:extra.crash_reason`. Custyard's conversation
  # LiveView keeps the raw access token (and prospect email) in socket assigns,
  # so a crash surfaces them as *bare values keyed by name* — e.g.
  # `access_token: "..."` — which the path patterns above cannot catch. These
  # patterns redact the value after a sensitive key, in both the atom-key
  # inspect form (`key: "value"`) and the string-key map form (`"key" =>
  # "value"`). The names below are matched as substrings on purpose (so
  # `sender_email:` is covered by `email`), but `access_token_hash:` is NOT
  # matched — a non-reversible hash is safe and useful for correlation — because
  # the trailing `:` in the pattern only lines up with the key itself.
  # The `\\*` before each quote tolerates escaped quotes: a crash report nests
  # an already-inspected socket string, so the outer inspect renders the value
  # as `access_token: \"...\"` (backslash-quote), not a bare `"..."`. The value
  # class excludes both quote and backslash so it stops at the closing delimiter.
  # Subset used for the free-form-text regex below: distinctive names only (no
  # bare `key`/`as`, which would over-match legitimate `key: "..."` fields
  # everywhere in inspected structs). Exact structured-key matching uses the
  # broader @sensitive_keys above. `verification_code` / `verification_link`
  # are a channel's captured forwarding confirmation, held in the setup
  # wizard's assigns; `token` already covers `ingress_token` as a substring.
  @sensitive_value_keys ~w(access_token org_token callback_token token credential passphrase secret password email verification_code verification_link)
  @key_alternation Enum.join(@sensitive_value_keys, "|")
  @atom_kv_pattern ~r/((?:#{@key_alternation}):\s*)\\*"[^"\\]*\\*"/
  @string_kv_pattern ~r/(\\*"(?:#{@key_alternation})\\*"\s*=>\s*)\\*"[^"\\]*\\*"/

  # URI userinfo (`scheme://user:password@host`), e.g. the AMQP broker URL that
  # amqp_client embeds whole in its parse errors. RFC 3986 userinfo cannot
  # contain a raw `/`, `?`, `#` or `@` delimiter, so the greedy class runs to
  # the last `@` before the host; a double quote or backslash ends it so an
  # inspected term's closing delimiter is never consumed.
  @userinfo_pattern ~r{([a-z][a-z0-9+.\-]*://)[^/?#\s"\\]+@}i

  @doc false
  def logger_handler_config do
    %{
      config: %{
        capture_log_messages: true,
        capture_level: :error,
        capture_metadata: :all,
        tags_from_metadata: [:custyard_event, :request_id, :operation_id, :error_type]
      }
    }
  end

  @doc """
  `:url_scrubber` for `Sentry.PlugContext` — `(Plug.Conn.t()) -> String.t()`.

  Mirrors `Sentry.PlugContext.default_url_scrubber/1` (build the request URL,
  then scrub) but additionally redacts sensitive path segments.
  """
  @spec scrub_conn_url(Plug.Conn.t()) :: String.t()
  def scrub_conn_url(conn) do
    conn
    |> Plug.Conn.request_url()
    |> scrub_url()
  end

  @doc """
  `:body_scrubber` for `Sentry.PlugContext`.

  Returns an empty map: Custyard's public-intake bodies carry prospect PII
  (name, email, message text) and portal replies, none of which belongs in an
  error report. Sending no params is the secure default; operators who need a
  specific field can opt it in later via a narrower scrubber.
  """
  @spec scrub_conn_body(Plug.Conn.t()) :: map()
  def scrub_conn_body(_conn), do: %{}

  @doc """
  Global `:before_send` callback — `(Sentry.Event.t()) -> Sentry.Event.t() | nil`.

  Drops unmatched-route 404s and reconstructs every other event using approved
  diagnostics only. Free-form strings are not treated as safe merely because
  they do not match a credential regex. Unexpected input is dropped.
  """
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def before_send(%Sentry.Event{} = event) do
    if drop?(event) do
      nil
    else
      scrub_event(event)
    end
  rescue
    _ -> fail_closed(event)
  end

  # Non-event input should not occur, but never crash the send pipeline.
  def before_send(_other), do: nil

  @doc """
  Scrubs a full URL string: redacts sensitive path segments and query-param
  values, preserving everything else. Returns `nil`/`""` unchanged.
  """
  @spec scrub_url(String.t() | nil) :: String.t() | nil
  def scrub_url(nil), do: nil
  def scrub_url(""), do: ""

  def scrub_url(url) when is_binary(url) do
    uri = URI.parse(url)

    %{uri | path: scrub_path(uri.path), query: scrub_query(uri.query)}
    |> URI.to_string()
  rescue
    _ -> @scrub_failed
  end

  @doc """
  Whether `path` carries one of Custyard's path-borne bearer credentials
  (the same prefixes `scrub_path/1` redacts). `CustyardWeb.Endpoint` uses it
  to keep those requests out of the request log.
  """
  @spec token_path?(String.t() | nil) :: boolean()
  def token_path?(path) when is_binary(path) do
    Enum.any?(@path_patterns, &Regex.match?(&1, path))
  end

  def token_path?(_path), do: false

  @doc """
  Redacts the credential segment after each known sensitive path prefix. Works
  on a bare path or on free-form text containing such a path. `nil` passes
  through.
  """
  @spec scrub_path(String.t() | nil) :: String.t() | nil
  def scrub_path(nil), do: nil

  def scrub_path(path) when is_binary(path) do
    Enum.reduce(@path_patterns, path, fn pattern, acc ->
      Regex.replace(pattern, acc, "\\1#{@redacted}")
    end)
  end

  @doc """
  Scrubs free-form text (crash messages, `:extra` string values): redacts URI
  userinfo (`amqp://user:password@host` -> `amqp://[REDACTED]@host`),
  sensitive URL path tokens *and* the value of any sensitive key in inspected
  Elixir terms (`access_token: "..."`, `"token" => "..."`). `nil` passes
  through. This is what protects the LiveView/process-crash path, where the
  token surfaces as a bare keyed value rather than in the request URL.
  """
  @spec scrub_text(String.t() | nil) :: String.t() | nil
  def scrub_text(nil), do: nil

  def scrub_text(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@userinfo_pattern, &1, "\\1#{@redacted}@"))
    |> scrub_path()
    |> then(&Regex.replace(@atom_kv_pattern, &1, "\\1\"#{@redacted}\""))
    |> then(&Regex.replace(@string_kv_pattern, &1, "\\1\"#{@redacted}\""))
  end

  @doc """
  Redacts the values of sensitive query parameters in a query string, leaving
  parameter names and non-sensitive values intact. `nil`/`""` pass through.
  """
  @spec scrub_query(String.t() | nil) :: String.t() | nil
  def scrub_query(nil), do: nil
  def scrub_query(""), do: ""

  def scrub_query(query) when is_binary(query) do
    # Rebuild manually rather than via URI.encode_query/1 so the redaction
    # marker stays a readable literal (encode_query would turn "[REDACTED]"
    # into "%5BREDACTED%5D"); non-sensitive values are still re-encoded.
    query
    |> URI.query_decoder()
    |> Enum.map_join("&", fn {key, value} ->
      encoded_key = URI.encode_www_form(key)

      cond do
        sensitive_key?(key) -> "#{encoded_key}=#{@redacted}"
        # Flag-style params (`?debug`) decode to "" (and defensively guard nil);
        # emit just the key rather than an empty `key=`.
        value in [nil, ""] -> encoded_key
        true -> "#{encoded_key}=#{URI.encode_www_form(value)}"
      end
    end)
  end

  defp sensitive_key?(key) when is_binary(key),
    do: String.downcase(key) in @sensitive_keys

  defp sensitive_key?(key), do: sensitive_key?(to_string(key))

  # -- internals -------------------------------------------------------------

  # Single place for event filtering (noise drops). Deliberately narrow: only
  # unmatched-route 404s. `before_send` is a security hook, not a general event
  # filter — add any future noise filters here, as explicit clauses, not by
  # broadening before_send.
  defp drop?(%Sentry.Event{original_exception: %Phoenix.Router.NoRouteError{}}), do: true
  defp drop?(_event), do: false

  # Start from a fresh struct. A newly added SDK field is private until it is
  # explicitly reviewed here, including fields used outside JSON serialization
  # (attachments and original_exception).
  defp scrub_event(event) do
    logger_metadata = field(event.extra, :logger_metadata)

    event_name =
      Custyard.Log.safe_event_name(field(logger_metadata, :custyard_event)) ||
        Custyard.Log.safe_event_name(field(event.extra, :event)) ||
        Custyard.Log.safe_event_name(field(event.tags, :custyard_event)) ||
        Custyard.Log.safe_event_name(field(event.tags, :event)) ||
        message_event_name(event.message)

    origin =
      Custyard.Log.safe_origin(field(logger_metadata, :origin)) ||
        Custyard.Log.safe_origin(field(logger_metadata, :mfa)) ||
        Custyard.Log.safe_origin(field(event.extra, :origin)) ||
        Custyard.Log.safe_origin(field(event.tags, :origin))

    diagnostics = Custyard.Log.sanitize_metadata(%{event: event_name, origin: origin})

    extra =
      event.extra
      |> safe_metadata()
      |> Map.merge(safe_metadata(logger_metadata))
      |> Map.merge(diagnostics)

    tags = event.tags |> safe_metadata() |> Map.merge(diagnostics)
    exceptions = safe_exceptions(event.exception)
    threads = safe_threads(event.threads)

    %Sentry.Event{
      event_id: safe_event_id(event.event_id),
      timestamp: safe_timestamp(event.timestamp),
      platform: :elixir,
      environment: safe_environment(),
      release: safe_release(),
      level: safe_level(event.level),
      exception: exceptions,
      message: safe_message(event.message, event_name),
      request: safe_request(event.request),
      threads: threads,
      extra: extra,
      tags: tags,
      fingerprint: safe_fingerprint(event_name, origin, exceptions, threads, extra),
      sdk: %Sentry.Interfaces.SDK{
        name: "sentry-elixir",
        version: Application.spec(:sentry, :vsn) |> to_string()
      }
    }
  end

  defp safe_metadata(value) when is_map(value) and not is_struct(value),
    do: Custyard.Log.sanitize_metadata(value)

  defp safe_metadata(_value), do: %{}

  defp field(value, key) when is_map(value) and not is_struct(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp field(_value, _key), do: nil

  defp message_event_name(%Sentry.Interfaces.Message{} = message),
    do:
      Custyard.Log.safe_event_name(message.formatted) ||
        Custyard.Log.safe_event_name(message.message)

  defp message_event_name(_message), do: nil

  # Every component is reconstructed from registered events, loaded code,
  # exception identity, or bounded numeric line information. Client-supplied
  # fingerprint values never participate in grouping.
  defp safe_fingerprint(event, origin, exceptions, threads, extra) do
    types = Enum.map_join(exceptions, "|", & &1.type)
    class = if types == "", do: extra[:error_type] || "UnknownError", else: types

    location =
      origin || first_frame_location(exceptions ++ List.wrap(threads)) || "unknown_origin"

    ["custyard", event || "application_error", class, location]
  end

  defp first_frame_location(interfaces) do
    Enum.find_value(interfaces, fn
      %{stacktrace: %Sentry.Interfaces.Stacktrace{frames: frames}} when is_list(frames) ->
        Enum.find_value(frames, fn
          %Sentry.Interfaces.Stacktrace.Frame{module: module, lineno: line} ->
            "#{module}:#{line || 0}"

          _ ->
            nil
        end)

      _ ->
        nil
    end)
  end

  defp safe_event_id(id) when is_binary(id) do
    if byte_size(id) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, id),
      do: id,
      else: new_event_id()
  end

  defp safe_event_id(_id), do: new_event_id()
  defp new_event_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp safe_timestamp(timestamp) when is_binary(timestamp) and byte_size(timestamp) <= 40 do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _offset} -> DateTime.to_iso8601(time)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp safe_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp safe_environment do
    allowed = Application.get_env(:custyard, :log_environments, ~w(dev test prod))

    configured =
      case Application.get_env(:sentry, :environment_name) do
        value when is_binary(value) -> value
        value when is_atom(value) -> Atom.to_string(value)
        _ -> nil
      end

    if is_list(allowed) and configured in allowed do
      configured
    else
      case Application.get_env(:custyard, :env) do
        env when env in [:dev, :test, :prod] -> Atom.to_string(env)
        _ -> "unknown"
      end
    end
  end

  defp safe_release do
    case Application.get_env(:sentry, :release) do
      value when is_binary(value) and byte_size(value) <= 80 ->
        if Regex.match?(~r/\A(?:[0-9a-f]{7,64}|v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\z/, value),
          do: value,
          else: nil

      _ ->
        nil
    end
  end

  defp safe_level(level) when level in [:debug, :info, :warning, :error, :fatal],
    do: Atom.to_string(level)

  defp safe_level(level) when level in ["debug", "info", "warning", "error", "fatal"], do: level
  defp safe_level(_level), do: "error"

  defp safe_message(nil, nil), do: nil

  defp safe_message(_message, event_name) do
    name = event_name || "application_error"
    %Sentry.Interfaces.Message{message: name, formatted: name, params: []}
  end

  # The host, arbitrary path segments, query names and query values can all be
  # user controlled. Retain only a known route template, never the original URL.
  defp safe_request(%Sentry.Interfaces.Request{} = request) do
    %Sentry.Interfaces.Request{
      method: safe_method(request.method),
      url: safe_route(request.url)
    }
  end

  defp safe_request(_request), do: %Sentry.Interfaces.Request{}

  defp safe_method(method)
       when method in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE),
       do: method

  defp safe_method(_method), do: nil

  defp safe_route(nil), do: nil

  defp safe_route(url) when is_binary(url) and byte_size(url) <= 8192 do
    url |> URI.parse() |> Map.get(:path) |> safe_route_path()
  end

  defp safe_route(_url), do: nil

  defp safe_route_path(path)
       when path in ["/", "/operator", "/operator/login", "/operator/login/sent", "/api/health"],
       do: path

  defp safe_route_path("/operator/login/verify/" <> _token),
    do: "/operator/login/verify/[REDACTED]"

  defp safe_route_path("/api/webhook/route/" <> _token),
    do: "/api/webhook/route/[REDACTED]"

  defp safe_route_path("/claim/" <> _token), do: "/claim/[REDACTED]"
  defp safe_route_path("/c/" <> _token), do: "/c/[REDACTED]"
  defp safe_route_path("/p/" <> _token), do: "/p/[REDACTED]"
  defp safe_route_path("/i/" <> _source), do: "/i/[REDACTED]"
  defp safe_route_path("/operator/" <> _path), do: "/operator/[OTHER]"
  defp safe_route_path(_path), do: "/[OTHER]"

  defp safe_exceptions(exceptions) when is_list(exceptions) do
    exceptions
    |> Enum.take(8)
    |> Enum.flat_map(fn
      %Sentry.Interfaces.Exception{} = exception ->
        [
          %Sentry.Interfaces.Exception{
            type: safe_exception_type(exception.type),
            value: @redacted,
            stacktrace: safe_stacktrace(exception.stacktrace),
            mechanism: safe_mechanism(exception.mechanism)
          }
        ]

      _ ->
        []
    end)
  end

  defp safe_exceptions(_exceptions), do: []

  defp safe_exception_type(type) when is_binary(type) and byte_size(type) <= 160 do
    name = if String.starts_with?(type, "Elixir."), do: type, else: "Elixir." <> type
    module = String.to_existing_atom(name)

    if :code.is_loaded(module) != false and function_exported?(module, :exception, 1),
      do: inspect(module),
      else: "UnknownError"
  rescue
    _ -> "UnknownError"
  end

  defp safe_exception_type(_type), do: "UnknownError"

  defp safe_mechanism(%Sentry.Interfaces.Exception.Mechanism{} = mechanism) do
    %Sentry.Interfaces.Exception.Mechanism{
      type: "generic",
      handled: safe_boolean(mechanism.handled),
      synthetic: safe_boolean(mechanism.synthetic)
    }
  end

  defp safe_mechanism(_mechanism), do: nil

  defp safe_stacktrace(%Sentry.Interfaces.Stacktrace{frames: frames}) when is_list(frames) do
    %Sentry.Interfaces.Stacktrace{
      frames: frames |> Enum.take(100) |> Enum.flat_map(&safe_frame/1)
    }
  end

  defp safe_stacktrace(_stacktrace), do: nil

  defp safe_frame(%Sentry.Interfaces.Stacktrace.Frame{} = frame) do
    case safe_module(frame.module) do
      nil ->
        []

      module ->
        [
          %Sentry.Interfaces.Stacktrace.Frame{
            module: module,
            function: safe_function(frame.function, module),
            filename: module_filename(module),
            lineno: safe_positive_integer(frame.lineno, 1_000_000),
            colno: safe_positive_integer(frame.colno, 10_000),
            in_app:
              String.starts_with?(Atom.to_string(module), [
                "Elixir.Custyard.",
                "Elixir.CustyardWeb."
              ])
          }
        ]
    end
  end

  defp safe_frame(_frame), do: []

  defp safe_module(module) when is_atom(module) and not is_nil(module) do
    if :code.is_loaded(module) != false, do: module, else: nil
  end

  defp safe_module(_module), do: nil

  # SDK function strings are reconstructed from an actual exported MFA. Private
  # or unusual function formats retain the module and line instead of echoing
  # an unverifiable string supplied on an event.
  defp safe_function(function, module) when is_binary(function) and byte_size(function) <= 200 do
    Enum.find_value(module.module_info(:exports), fn {name, arity} ->
      known = Exception.format_mfa(module, name, arity)
      if function == known, do: known
    end)
  rescue
    _ -> nil
  end

  defp safe_function(_function, _module), do: nil

  defp module_filename(module) do
    case module.module_info(:compile)[:source] do
      source when is_list(source) -> source |> List.to_string() |> Path.basename()
      source when is_binary(source) -> Path.basename(source)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_threads(threads) when is_list(threads) do
    threads
    |> Enum.take(16)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%Sentry.Interfaces.Thread{} = thread, index} ->
        [
          %Sentry.Interfaces.Thread{
            id: index,
            crashed: safe_boolean(thread.crashed),
            current: safe_boolean(thread.current),
            main: safe_boolean(thread.main),
            stacktrace: safe_stacktrace(thread.stacktrace)
          }
        ]

      _ ->
        []
    end)
  end

  defp safe_threads(_threads), do: nil

  defp safe_boolean(value) when is_boolean(value), do: value
  defp safe_boolean(_value), do: nil

  defp safe_positive_integer(value, limit)
       when is_integer(value) and value > 0 and value <= limit,
       do: value

  defp safe_positive_integer(_value, _limit), do: nil

  # This path deliberately does not call any minimization helper or retain any
  # original field, so a broken helper cannot turn the fallback into a leak.
  defp fail_closed(_event) do
    %Sentry.Event{
      event_id: new_event_id(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      environment: "unknown",
      platform: :elixir,
      level: "error",
      message: %Sentry.Interfaces.Message{
        message: "sentry_scrubbing_failed",
        formatted: "sentry_scrubbing_failed",
        params: []
      }
    }
  end
end

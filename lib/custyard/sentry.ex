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

  Scrubbing is **fail-closed**: if anything raises mid-scrub, the affected field
  is replaced with `#{"[SCRUBBING_FAILED]"}` rather than left intact, so a bug
  in this module can never leak the value it was meant to hide.
  """

  @redacted "[REDACTED]"
  @scrub_failed "[SCRUBBING_FAILED]"

  # Query-parameter names (compared case-insensitively) whose *values* must
  # never reach Sentry. Covers the path-token names when they also appear as
  # query params, plus generic secret-bearing names and the dev-only
  # `?as=<contact_id>` impersonation param.
  @sensitive_query_params ~w(token key secret passphrase password callback_token org_token as)

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
  @sensitive_value_keys ~w(access_token org_token callback_token token passphrase secret password email)
  @key_alternation Enum.join(@sensitive_value_keys, "|")
  @atom_kv_pattern ~r/((?:#{@key_alternation}):\s*)\\*"[^"\\]*\\*"/
  @string_kv_pattern ~r/(\\*"(?:#{@key_alternation})\\*"\s*=>\s*)\\*"[^"\\]*\\*"/

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

  Drops known-noise events (unmatched-route 404s) and scrubs the request URL,
  query string and message on everything else. Fail-closed: on any error the
  request URL/message are redacted with a placeholder and the (scrubbed) event
  is still reported, so genuine errors are never silently swallowed.
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
  def before_send(other), do: other

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
  Scrubs free-form text (crash messages, `:extra` string values): redacts
  sensitive URL path tokens *and* the value of any sensitive key in inspected
  Elixir terms (`access_token: "..."`, `"token" => "..."`). `nil` passes
  through. This is what protects the LiveView/process-crash path, where the
  token surfaces as a bare keyed value rather than in the request URL.
  """
  @spec scrub_text(String.t() | nil) :: String.t() | nil
  def scrub_text(nil), do: nil

  def scrub_text(text) when is_binary(text) do
    text
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

      if sensitive_param?(key) do
        "#{encoded_key}=#{@redacted}"
      else
        "#{encoded_key}=#{URI.encode_www_form(value)}"
      end
    end)
  end

  # -- internals -------------------------------------------------------------

  # Only unmatched-route 404s are dropped, and only via this one explicit
  # clause — `before_send` is a security hook, not a general event filter.
  defp drop?(%Sentry.Event{original_exception: %Phoenix.Router.NoRouteError{}}), do: true
  defp drop?(_event), do: false

  defp scrub_event(event) do
    event
    |> scrub_request()
    |> scrub_message()
    |> scrub_extra()
  end

  defp scrub_request(%Sentry.Event{request: %Sentry.Interfaces.Request{} = req} = event) do
    scrubbed = %{
      req
      | url: scrub_url(req.url),
        query_string: scrub_query_field(req.query_string)
    }

    %{event | request: scrubbed}
  end

  defp scrub_request(event), do: event

  # LiveView/process crashes reported via Sentry.LoggerHandler never pass
  # through PlugContext: the token surfaces inside the inspected crash state in
  # the message, as `access_token: "..."` — scrub_text redacts both URL tokens
  # and keyed values there.
  defp scrub_message(%Sentry.Event{message: %Sentry.Interfaces.Message{} = msg} = event) do
    scrubbed = %{
      msg
      | message: scrub_text(msg.message),
        formatted: scrub_text(msg.formatted)
    }

    %{event | message: scrubbed}
  end

  defp scrub_message(event), do: event

  # :extra carries `crash_reason` (an inspected exit reason that, for a crashed
  # LiveView, embeds the socket state and its raw access token). Redact any
  # value under a sensitive key outright, and scrub sensitive keyed values out
  # of string values (crash_reason) in place, keeping the rest for debugging.
  defp scrub_extra(%Sentry.Event{extra: extra} = event) when is_map(extra) do
    scrubbed =
      Map.new(extra, fn {key, value} ->
        cond do
          sensitive_param?(key) -> {key, @redacted}
          is_binary(value) -> {key, scrub_text(value)}
          true -> {key, value}
        end
      end)

    %{event | extra: scrubbed}
  end

  defp scrub_extra(event), do: event

  # query_string may be a raw string, a map, or a keyword-ish list.
  defp scrub_query_field(nil), do: nil
  defp scrub_query_field(query) when is_binary(query), do: scrub_query(query)

  defp scrub_query_field(query) when is_map(query) do
    Map.new(query, fn {k, v} -> {k, if(sensitive_param?(k), do: @redacted, else: v)} end)
  end

  defp scrub_query_field(query) when is_list(query) do
    Enum.map(query, fn {k, v} -> {k, if(sensitive_param?(k), do: @redacted, else: v)} end)
  end

  defp scrub_query_field(other), do: other

  defp sensitive_param?(key) when is_binary(key),
    do: String.downcase(key) in @sensitive_query_params

  defp sensitive_param?(key), do: sensitive_param?(to_string(key))

  # Last-resort redaction when scrubbing itself raised: never keep any
  # potentially-sensitive field, but still report the event so the underlying
  # error stays visible. Blanks the request URL/query, the crash message, and
  # every :extra value.
  defp fail_closed(%Sentry.Event{} = event) do
    event
    |> put_in_request(:url, @scrub_failed)
    |> put_in_request(:query_string, @scrub_failed)
    |> blank_message()
    |> blank_extra()
  end

  defp fail_closed(event), do: event

  defp put_in_request(
         %Sentry.Event{request: %Sentry.Interfaces.Request{} = req} = event,
         key,
         value
       ) do
    %{event | request: Map.put(req, key, value)}
  end

  defp put_in_request(event, _key, _value), do: event

  defp blank_message(%Sentry.Event{message: %Sentry.Interfaces.Message{} = msg} = event) do
    %{event | message: %{msg | message: @scrub_failed, formatted: @scrub_failed}}
  end

  defp blank_message(event), do: event

  defp blank_extra(%Sentry.Event{extra: extra} = event) when is_map(extra) do
    %{event | extra: Map.new(extra, fn {key, _value} -> {key, @scrub_failed} end)}
  end

  defp blank_extra(event), do: event
end

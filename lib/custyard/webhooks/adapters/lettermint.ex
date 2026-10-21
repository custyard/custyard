defmodule Custyard.Webhooks.Adapters.Lettermint do
  @moduledoc """
  Webhook adapter for Lettermint email service.

  Lettermint signs `timestamp.raw_body` with HMAC-SHA256 and sends the timestamp
  and hex digest together in `X-Lettermint-Signature: t=...,v1=...`.

  ## Payload shapes

  Lettermint posts an enveloped event:

      %{"id" => delivery_id, "event" => "message.inbound", "timestamp" => ..., "data" => %{...}}

  `id` is the webhook delivery id and is reused on every retry of the same
  delivery, so it is surfaced as `metadata.provider_delivery_id` for dedup.
  `data` carries the parsed mail: `from` (`%{"email", "name"}`), `to`/`cc`
  (lists of the same), `recipient` (SMTP envelope recipient, the routing key),
  `subject`, `body` (`%{"text", "html"}`), `headers` (a list of
  `%{"name", "value"}` holding Message-ID, In-Reply-To, References and any
  non-standard headers), `authentication_results`, `is_spam`, `spam_score`.
  Events other than `message.inbound` return
  `{:bypass, %{type: "ignored_event", event: event}}` so the controller can
  acknowledge them without processing.

  The flat legacy shape (`from`, `to`, `subject`, `text`, `html` and a
  `headers` map) is still accepted for dev fixtures and direct posts.

  Only a compact metadata map is retained: no raw-message URL, attachment
  content, spam symbols, remote IP or full header list (see
  docs/design/spec-inbound-channels.md, "Privacy and compliance"). The
  envelope sender (`envelope.mail_from`) is kept because an empty value marks
  a delivery status notification for triage; `""` is preserved as-is and the
  key is nil when the envelope is absent.
  """
  @behaviour Custyard.Webhooks.Adapter

  # Maximum allowed time skew for timestamp validation (5 minutes)
  @max_timestamp_skew 60 * 5

  @impl true
  def source_name, do: :lettermint

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(payload),
    do: verify_request(payload, nil, signature, secret)

  def verify_signature(_payload, _signature, _secret),
    do: {:error, "missing signature header"}

  @doc """
  Verify the signed timestamp and exact raw body with replay protection.
  """
  @impl true
  def verify_request(_raw_body, _timestamp, _signature, nil), do: {:error, "no secret configured"}

  def verify_request(raw_body, _timestamp, signature, secret) when is_binary(raw_body) do
    with {:ok, timestamp, provided} <- parse_signature(signature),
         :ok <- validate_timestamp(timestamp) do
      expected =
        :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw_body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, String.downcase(provided)),
        do: :ok,
        else: {:error, "invalid signature"}
    end
  end

  defp parse_signature(nil), do: {:error, "missing signature header"}

  defp parse_signature(signature) when is_binary(signature) do
    parts =
      signature
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))

    with [timestamp] <- for(["t", value] <- parts, do: value),
         [digest] <- for(["v1", value] <- parts, do: value),
         true <- byte_size(digest) == 64 and String.match?(digest, ~r/\A[0-9a-fA-F]{64}\z/) do
      {:ok, timestamp, digest}
    else
      _ -> {:error, "invalid signature format"}
    end
  end

  defp validate_timestamp(timestamp_str) when is_binary(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {timestamp, ""} ->
        now = System.system_time(:second)

        if abs(now - timestamp) <= @max_timestamp_skew do
          :ok
        else
          {:error, "stale timestamp - request may be a replay attack"}
        end

      _ ->
        {:error, "invalid timestamp format"}
    end
  end

  alias Custyard.Email.{HtmlSanitizer, Normalizer}

  @impl true
  def normalize(%{"event" => "message.inbound", "data" => data} = params) when is_map(data) do
    normalize_inbound(data, params["id"])
  end

  def normalize(%{"event" => event, "data" => data}) when is_map(data) do
    {:bypass, %{type: "ignored_event", event: event}}
  end

  def normalize(params) do
    headers = if is_map(params["headers"]), do: params["headers"], else: %{}

    body =
      Normalizer.presence(params["text"]) || Normalizer.strip_html(params["html"]) || ""

    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject: normalize_subject(params["subject"]),
       body: Normalizer.truncate(body, Normalizer.max_body_length()),
       message_id: Normalizer.get_header(headers, "message-id"),
       in_reply_to: Normalizer.get_header(headers, "in-reply-to"),
       references: Normalizer.get_header(headers, "references"),
       headers: headers,
       source: :lettermint,
       metadata: %{html_body: HtmlSanitizer.sanitize(params["html"])}
     }}
  end

  defp normalize_inbound(data, delivery_id) do
    headers = headers_map(data["headers"])
    body_map = if is_map(data["body"]), do: data["body"], else: %{}

    body =
      Normalizer.presence(body_map["text"]) || Normalizer.strip_html(body_map["html"]) || ""

    {:ok,
     %{
       from: format_from(data["from"]),
       to: Normalizer.presence(data["recipient"]) || first_email(data["to"]),
       subject: normalize_subject(data["subject"]),
       body: Normalizer.truncate(body, Normalizer.max_body_length()),
       message_id: Normalizer.get_header(headers, "message-id"),
       in_reply_to: Normalizer.get_header(headers, "in-reply-to"),
       references: Normalizer.get_header(headers, "references"),
       headers: headers,
       source: :lettermint,
       metadata: metadata(delivery_id, data)
     }}
  end

  defp normalize_subject(subject) do
    Normalizer.truncate(
      Normalizer.presence(subject) || "(no subject)",
      Normalizer.max_subject_length()
    )
  end

  # `Name <email>` when a safe display name is present, else the bare address.
  # SenderMatcher.extract_email/1 parses this form; a name carrying angle
  # brackets or control characters would corrupt that parse (or a later
  # header), so it is dropped rather than escaped.
  defp format_from(%{"email" => email} = from) when is_binary(email) do
    case safe_display_name(from["name"]) do
      nil -> email
      name -> "#{name} <#{email}>"
    end
  end

  defp format_from(_from), do: nil

  @unsafe_name ~r/[<>\x00-\x1F\x7F]/

  defp safe_display_name(name) when is_binary(name) do
    case Normalizer.presence(name) do
      nil -> nil
      present -> if Regex.match?(@unsafe_name, present), do: nil, else: String.trim(present)
    end
  end

  defp safe_display_name(_name), do: nil

  defp first_email([%{"email" => email} | _rest]) when is_binary(email), do: email
  defp first_email([_other | rest]), do: first_email(rest)
  defp first_email(_list), do: nil

  # Lettermint sends headers as [%{"name", "value"}]; the rest of the pipeline
  # (Normalizer.get_header/2, SieveHeaderMapper) expects a map. The first
  # occurrence of a name wins. Entries of any other shape are ignored.
  defp headers_map(list) when is_list(list) do
    Enum.reduce(list, %{}, fn
      %{"name" => name, "value" => value}, acc when is_binary(name) and is_binary(value) ->
        Map.put_new(acc, name, value)

      _entry, acc ->
        acc
    end)
  end

  defp headers_map(map) when is_map(map), do: map
  defp headers_map(_other), do: %{}

  defp metadata(delivery_id, data) do
    auth =
      if is_map(data["authentication_results"]), do: data["authentication_results"], else: %{}

    body_map = if is_map(data["body"]), do: data["body"], else: %{}

    %{
      provider_delivery_id: string_or_nil(delivery_id),
      lettermint_message_id: string_or_nil(data["message_id"]),
      recipient: string_or_nil(data["recipient"]),
      subaddress: string_or_nil(data["subaddress"]),
      # Header To addresses, kept apart from the envelope recipient: for a
      # forwarded delivery the recipient is the secret ingress address and
      # must not be displayed as the customer's To.
      to: address_emails(data["to"]),
      mail_from: envelope_mail_from(data["envelope"]),
      reply_to: string_or_nil(data["reply_to"]),
      cc: address_emails(data["cc"]),
      # Anchor hrefs from the HTML body, for verification-link extraction
      # only (strip_html/1 drops them); never persisted on the message.
      links: html_links(body_map["html"]),
      # Allowlist-sanitised HTML (D9); the raw markup goes no further.
      html_body: HtmlSanitizer.sanitize(body_map["html"]),
      authentication: %{
        dkim: auth_field(auth["dkim"], "result"),
        dkim_domain: auth_field(auth["dkim"], "domain"),
        spf: auth_field(auth["spf"], "result"),
        dmarc: auth_field(auth["dmarc"], "result")
      },
      is_spam: if(is_boolean(data["is_spam"]), do: data["is_spam"]),
      spam_score: if(is_number(data["spam_score"]), do: data["spam_score"])
    }
  end

  # "" is a bounce or DSN (null reverse path) and must survive as "".
  defp envelope_mail_from(%{"mail_from" => mail_from}) when is_binary(mail_from), do: mail_from
  defp envelope_mail_from(_envelope), do: nil

  defp address_emails(list) when is_list(list) do
    for %{"email" => email} <- list, is_binary(email), do: email
  end

  defp address_emails(_other), do: []

  @href_regex ~r/href\s*=\s*["']?(https:\/\/[^"'\s>]+)/i
  @max_links 50

  defp html_links(html) when is_binary(html) do
    @href_regex
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [url] -> String.replace(url, "&amp;", "&") end)
    |> Enum.uniq()
    |> Enum.take(@max_links)
  end

  defp html_links(_html), do: []

  defp auth_field(%{} = section, key), do: string_or_nil(section[key])
  defp auth_field(_section, _key), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end

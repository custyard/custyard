defmodule Custyard.Webhooks.Triage do
  @moduledoc """
  Classifies an inbound delivery before sender matching runs
  (docs/design/spec-inbound-channels.md, D6).

  `classify/3` is a pure decision: it reads the normalized payload, the
  route and the resolved channel (nil on a legacy route), queries the
  database only to look up existing rows, and never writes. The dispatcher
  acts on the result.

  Classes, checked in this order; the first match wins:

    1. `{:own_echo, %Message{}}` - the Message-ID belongs to an operator
       reply Custyard sent from this organization (D4 archive copy).
    2. `{:operator_sent, %{conversation:, operator:, email:}}` - a reply the
       operator sent from their own mailbox, outside Custyard, that threads
       to a known conversation.
    3. `{:operator_forward, %{original:, operator:, email:}}` - customer
       mail an operator forwarded in by hand (the backlog-import path):
       the original sender, subject and body are unwrapped from the
       forwarded block.
    4. `{:verification, %{provider:, code:, link:}}` - a Gmail or Proton
       forwarding confirmation.
    5. `{:auto_response, reason}` - auto-submitted, bulk or bounce mail.
    6. `{:suspect, reason}` - spam-flagged or DKIM+DMARC failing mail from a
       sender who is not a known contact in the organization. A contact
       whose only conversations are themselves suspect does not count:
       suspect mail creates its own contact, and that must not whitelist
       the sender's next message. An operator clearing the suspect flag on
       any of those conversations is what makes the sender known.
    7. `{:customer, nil}` - everything else.

  Classes 2 and 3 need an authenticated operator identity: `From` is
  forgeable, so the sender must be an operator account of the organization
  (or the channel's own public address) *and* the forwarded copy must carry
  a DKIM pass whose signing domain is aligned with the sender's domain.
  Without that, the mail is customer mail from an unknown sender.
  """

  import Ecto.Query

  alias Custyard.{
    Contact,
    Conversation,
    InboundChannel,
    InboundRoute,
    Message,
    OperatorAccount,
    Repo
  }

  alias Custyard.Email.{ForwardUnwrapper, Normalizer, SenderMatcher, ThreadHeaders, ThreadMatcher}

  @type operator_identity :: %{operator: struct() | nil, email: String.t()}

  @type classification ::
          {:own_echo, struct()}
          | {:operator_sent,
             %{conversation: struct(), operator: struct() | nil, email: String.t()}}
          | {:operator_forward, %{original: map(), operator: struct() | nil, email: String.t()}}
          | {:verification,
             %{provider: :google | :proton, code: String.t() | nil, link: String.t() | nil}}
          | {:auto_response, atom()}
          | {:suspect, atom()}
          | {:customer, nil}

  @default_verification_senders %{
    google: ["forwarding-noreply@google.com"],
    proton: ["no-reply@notify.proton.me", "notify@proton.me"]
  }

  @verification_link_hosts %{google: ["google.com"], proton: ["proton.me"]}
  @google_subject ~r/forwarding confirmation/i
  @gmail_code ~r/\(#(\d{4,})\)/
  @https_url ~r/https:\/\/[^\s<>"'\]\)]+/
  @trailing_punctuation ~r/[.,;:]+\z/

  @bulk_precedence ~w(bulk junk auto_reply list)
  # `X-Auto-Response-Suppress` is deliberately absent: it asks the recipient
  # not to auto-reply and is set on plenty of human mail (Exchange, bulk
  # senders); it does not mark the message itself as automatic.
  @auto_reply_headers ["X-Autoreply", "X-Autorespond"]

  @doc """
  Classify `normalized` delivered on `route` to `channel` (nil for a legacy
  route without channels).
  """
  @spec classify(map(), struct(), struct() | nil) :: classification()
  def classify(normalized, %InboundRoute{} = route, channel) do
    sender = SenderMatcher.extract_email(normalized[:from])

    with nil <- own_echo(normalized, route.organization_id),
         nil <- operator_mail(normalized, sender, route, channel),
         nil <- verification(normalized, sender),
         nil <- auto_response(normalized),
         nil <- suspect(normalized, sender, route.organization_id) do
      {:customer, nil}
    end
  end

  # --- own echo (D4) ---

  defp own_echo(normalized, organization_id) do
    case echo_candidates(normalized[:message_id]) do
      [] ->
        nil

      candidates ->
        query =
          from m in Message,
            join: c in Conversation,
            on: c.id == m.conversation_id,
            where: m.source == :operator,
            where: is_nil(m.triage_class) or m.triage_class != :operator_sent,
            where: m.message_id in ^candidates,
            where: c.organization_id == ^organization_id,
            order_by: [asc: m.id],
            limit: 1

        case Repo.one(query) do
          nil -> nil
          message -> {:own_echo, message}
        end
    end
  end

  defp echo_candidates(message_id) when is_binary(message_id) do
    [message_id, ThreadHeaders.normalize_msg_id(message_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp echo_candidates(_message_id), do: []

  # --- operator-sent capture and manual forward (D6) ---

  defp operator_mail(_normalized, nil, _route, _channel), do: nil

  defp operator_mail(normalized, sender, route, channel) do
    case operator_identity(normalized, sender, route.organization_id, channel) do
      nil ->
        nil

      identity ->
        case ThreadMatcher.find_thread(normalized, route.organization_id) do
          {:ok, conversation} ->
            {:operator_sent, Map.put(identity, :conversation, conversation)}

          :not_found ->
            operator_forward(normalized, identity)
        end
    end
  end

  defp operator_forward(normalized, identity) do
    subject = normalized[:subject]
    body = normalized[:body]

    if ForwardUnwrapper.forward_subject?(subject) or ForwardUnwrapper.forwarded_block?(body) do
      case ForwardUnwrapper.unwrap(body, subject) do
        {:ok, original} -> {:operator_forward, Map.put(identity, :original, original)}
        :error -> nil
      end
    end
  end

  # The sender is operator-owned (an operator account of this organization,
  # or the channel's public address) and the DKIM signature on the forwarded
  # copy is from the sender's own domain.
  defp operator_identity(normalized, sender, organization_id, channel) do
    sender = String.downcase(sender)

    with true <- dkim_aligned?(normalized, sender),
         {:ok, operator} <- operator_owned(sender, organization_id, channel) do
      %{operator: operator, email: sender}
    else
      _not_operator -> nil
    end
  end

  defp operator_owned(sender, organization_id, channel) do
    case Repo.get_by(OperatorAccount, email: OperatorAccount.normalize_email(sender)) do
      %OperatorAccount{role: "super_admin"} = operator ->
        {:ok, operator}

      %OperatorAccount{organization_id: ^organization_id} = operator ->
        {:ok, operator}

      _other ->
        case channel do
          %InboundChannel{public_address: address} when is_binary(address) ->
            if String.downcase(address) == sender, do: {:ok, nil}, else: :error

          _no_channel ->
            :error
        end
    end
  end

  # DMARC-style relaxed alignment: the signing domain equals the sender's
  # domain or one is a parent of the other.
  defp dkim_aligned?(normalized, sender) do
    auth = get_in(normalized, [:metadata, :authentication]) || %{}
    dkim = auth[:dkim] || auth["dkim"]
    signing = auth[:dkim_domain] || auth["dkim_domain"]

    with true <- is_binary(dkim) and String.downcase(dkim) == "pass",
         true <- is_binary(signing),
         [_local, sender_domain] <- String.split(sender, "@", parts: 2) do
      signing = String.downcase(signing)
      sender_domain = String.downcase(sender_domain)

      signing == sender_domain or String.ends_with?(sender_domain, "." <> signing) or
        String.ends_with?(signing, "." <> sender_domain)
    else
      _not_aligned -> false
    end
  end

  # --- provider verification (D6) ---

  defp verification(_normalized, nil), do: nil

  defp verification(normalized, sender) do
    case verification_provider(sender, normalized[:subject]) do
      nil ->
        nil

      provider ->
        {:verification,
         %{
           provider: provider,
           code: verification_code(provider, normalized[:subject]),
           link: verification_link(provider, normalized)
         }}
    end
  end

  defp verification_provider(sender, subject) do
    senders = verification_senders()

    cond do
      sender in Map.get(senders, :google, []) -> :google
      sender in Map.get(senders, :proton, []) -> :proton
      google_domain?(sender) and is_binary(subject) and subject =~ @google_subject -> :google
      true -> nil
    end
  end

  defp google_domain?(sender), do: String.ends_with?(sender, "@google.com")

  defp verification_senders do
    :custyard
    |> Application.get_env(:forwarding_verification_senders, @default_verification_senders)
    |> Map.new(fn {provider, addresses} ->
      {provider, Enum.map(List.wrap(addresses), &String.downcase/1)}
    end)
  end

  # Gmail puts the confirmation code in the subject as "(#123456789)".
  defp verification_code(:google, subject) when is_binary(subject) do
    case Regex.run(@gmail_code, subject) do
      [_, code] -> code
      nil -> nil
    end
  end

  defp verification_code(_provider, _subject), do: nil

  # First https link whose host belongs to the provider, searching the text
  # body and then the anchor hrefs the adapter lifted from an HTML body
  # (`metadata.links`): stripping HTML drops `href` attributes, so an
  # HTML-only confirmation would otherwise lose its link.
  defp verification_link(provider, normalized) do
    hosts = Map.fetch!(@verification_link_hosts, provider)

    body_links =
      case normalized[:body] do
        body when is_binary(body) ->
          @https_url
          |> Regex.scan(body)
          |> Enum.map(fn [url] -> Regex.replace(@trailing_punctuation, url, "") end)

        _other ->
          []
      end

    html_links =
      case get_in(normalized, [:metadata, :links]) do
        links when is_list(links) -> Enum.filter(links, &is_binary/1)
        _other -> []
      end

    Enum.find(body_links ++ html_links, &provider_link?(&1, hosts))
  end

  defp provider_link?(url, hosts) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)

        Enum.any?(hosts, fn suffix -> host == suffix or String.ends_with?(host, "." <> suffix) end)

      _uri ->
        false
    end
  end

  # --- auto-response / bulk / bounce ---

  defp auto_response(normalized) do
    headers = normalized[:headers] || %{}

    cond do
      auto_submitted?(headers) ->
        {:auto_response, :auto_submitted}

      bulk_precedence?(headers) ->
        {:auto_response, :precedence}

      Enum.any?(@auto_reply_headers, &present_header?(headers, &1)) ->
        {:auto_response, :auto_reply_header}

      get_in(normalized, [:metadata, :mail_from]) == "" ->
        {:auto_response, :empty_envelope_sender}

      true ->
        nil
    end
  end

  # RFC 3834: any value other than "no" marks an automatic message.
  defp auto_submitted?(headers) do
    case header_value(headers, "Auto-Submitted") do
      nil -> false
      value -> String.downcase(value) != "no"
    end
  end

  defp bulk_precedence?(headers) do
    case header_value(headers, "Precedence") do
      nil -> false
      value -> String.downcase(value) in @bulk_precedence
    end
  end

  defp present_header?(headers, name), do: Normalizer.get_header(headers, name) != nil

  # Normalizer.get_header/2 is case-insensitive on the name; the value is
  # trimmed here, and an empty value counts as absent.
  defp header_value(headers, name) do
    case Normalizer.get_header(headers, name) do
      value when is_binary(value) -> Normalizer.presence(String.trim(value))
      _other -> nil
    end
  end

  # --- suspect (spam-flagged or unauthenticated unknown sender) ---

  defp suspect(normalized, sender, organization_id) do
    metadata = normalized[:metadata] || %{}

    reason =
      cond do
        metadata[:is_spam] == true -> :spam_flagged
        authentication_failed?(metadata[:authentication]) -> :unauthenticated
        true -> nil
      end

    if reason && not known_contact?(sender, organization_id), do: {:suspect, reason}
  end

  # SPF is deliberately not a signal: it cannot pass through a forwarder
  # (spec, rejected alternatives).
  defp authentication_failed?(%{} = auth),
    do: fail?(auth[:dkim] || auth["dkim"]) and fail?(auth[:dmarc] || auth["dmarc"])

  defp authentication_failed?(_auth), do: false

  defp fail?(result) when is_binary(result), do: String.downcase(result) == "fail"
  defp fail?(_result), do: false

  defp known_contact?(nil, _organization_id), do: false

  # A contact counts as known unless every conversation it has is suspect.
  # Sender matching creates a contact for the first suspect delivery; without
  # this rule that contact would exempt the sender's second message. A
  # contact with no conversations at all (operator-created or imported) is
  # known, as is one with at least one conversation an operator accepted or
  # cleared.
  defp known_contact?(email, organization_id) do
    suspect_only =
      from v in Conversation,
        where: v.contact_id == parent_as(:contact).id and v.suspect == true

    accepted =
      from v in Conversation,
        where: v.contact_id == parent_as(:contact).id and v.suspect == false

    Repo.exists?(
      from c in Contact,
        as: :contact,
        where: c.email == ^email and c.organization_id == ^organization_id,
        where: not exists(suspect_only) or exists(accepted)
    )
  end
end

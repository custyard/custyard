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
    2. `{:verification, %{provider:, code:, link:}}` - a Gmail or Proton
       forwarding confirmation.
    3. `{:auto_response, reason}` - auto-submitted, bulk or bounce mail.
    4. `{:suspect, reason}` - spam-flagged or DKIM+DMARC failing mail from a
       sender who is not already a contact in the organization.
    5. `{:customer, nil}` - everything else.

  Operator-sent capture and manual-forward unwrap (Phase 2) are not
  implemented; such mail is customer mail here.
  """

  import Ecto.Query

  alias Custyard.{Contact, Conversation, InboundRoute, Message, Repo}
  alias Custyard.Email.{Normalizer, SenderMatcher, ThreadHeaders}

  @type classification ::
          {:own_echo, struct()}
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
  @auto_reply_headers ["X-Autoreply", "X-Autorespond", "X-Auto-Response-Suppress"]

  @doc """
  Classify `normalized` delivered on `route` to `channel` (nil for a legacy
  route without channels).
  """
  @spec classify(map(), struct(), struct() | nil) :: classification()
  def classify(normalized, %InboundRoute{} = route, _channel) do
    sender = SenderMatcher.extract_email(normalized[:from])

    with nil <- own_echo(normalized, route.organization_id),
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
           link: verification_link(provider, normalized[:body])
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

  # First https link in the body whose host belongs to the provider.
  defp verification_link(provider, body) when is_binary(body) do
    hosts = Map.fetch!(@verification_link_hosts, provider)

    @https_url
    |> Regex.scan(body)
    |> Enum.map(fn [url] -> Regex.replace(@trailing_punctuation, url, "") end)
    |> Enum.find(&provider_link?(&1, hosts))
  end

  defp verification_link(_provider, _body), do: nil

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

  defp known_contact?(email, organization_id) do
    Repo.exists?(
      from c in Contact,
        where: c.email == ^email and c.organization_id == ^organization_id
    )
  end
end

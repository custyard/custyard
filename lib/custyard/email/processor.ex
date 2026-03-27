defmodule Custyard.Email.Processor do
  @moduledoc """
  Process inbound emails from Lettermint webhook.

  Handles email parsing, sender matching, thread detection, and Sieve header
  metadata extraction. Custom headers injected by Sieve rules can override
  auto-detected properties like urgency.
  """

  alias Custyard.{Conversation, Message, Repo, Scoring}
  alias Custyard.Email.{SenderMatcher, SieveHeaderMapper, ThreadMatcher}

  def process(params) do
    with {:ok, parsed} <- parse_payload(params),
         {:ok, org, contact} <- SenderMatcher.match(parsed.from),
         {:ok, {conversation, is_new}} <- transact_conversation(parsed, org, contact) do
      broadcast_updates(conversation, is_new)
      {:ok, Repo.reload!(conversation)}
    end
  end

  defp transact_conversation(parsed, org, contact) do
    Repo.transaction(fn ->
      case find_or_create_conversation(parsed, org, contact) do
        {:ok, conversation, is_new} ->
          create_message(conversation, parsed)
          {conversation, is_new}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp broadcast_updates(conversation, is_new) do
    event = if is_new, do: :conversation_created, else: :conversation_updated
    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {event, conversation.id})

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations:org:#{conversation.organization_id}",
      {event, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )
  end

  defp parse_payload(params) do
    # Lettermint sends: from, to, subject, text, html, headers, attachments
    headers = params["headers"] || %{}

    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject: params["subject"] || "(no subject)",
       body: params["text"] || strip_html(params["html"]) || "",
       message_id: get_header(headers, "message-id"),
       in_reply_to: get_header(headers, "in-reply-to"),
       references: get_header(headers, "references"),
       # Preserve all headers for Sieve metadata extraction
       headers: headers
     }}
  end

  # Get header value, case-insensitive for header name
  defp get_header(headers, name) do
    # Try exact match first, fall back to case-insensitive lookup
    headers[name] || find_header_case_insensitive(headers, name)
  end

  defp find_header_case_insensitive(headers, name) do
    lowercase_name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == lowercase_name, do: v
    end)
  end

  defp strip_html(nil), do: nil

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp find_or_create_conversation(parsed, org, contact) do
    # Try threading first, scoped to the organization
    case ThreadMatcher.find_thread(parsed, org.id) do
      {:ok, conversation} ->
        # Reactivate if dormant/resolved
        conversation = maybe_reactivate(conversation)
        {:ok, conversation, false}

      :not_found ->
        # Create new conversation
        case create_conversation(parsed, org, contact) do
          {:ok, conversation} -> {:ok, conversation, true}
          error -> error
        end
    end
  end

  defp create_conversation(parsed, org, contact) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Start with auto-detected urgency
    base_attrs = %{
      organization_id: org.id,
      contact_id: contact && contact.id,
      subject: parsed.subject,
      state: :new,
      # Explicitly set source (LMTP path = direct email)
      source: :email,
      urgency: detect_urgency(parsed.subject, parsed.body),
      last_customer_action_at: now
    }

    # Apply Sieve header overrides (e.g., X-Priority -> urgency)
    attrs = SieveHeaderMapper.merge_overrides(base_attrs, parsed.headers)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @max_body_length 100_000

  defp create_message(conversation, parsed) do
    body = String.slice(parsed.body || "", 0, @max_body_length)

    # Use idempotent insert for duplicate email safety
    attrs = %{
      conversation_id: conversation.id,
      source: :email,
      # LMTP/direct email - origin tracks the adapter source
      origin: :email,
      sender_email: parsed.from,
      body: body,
      message_id: parsed.message_id,
      in_reply_to: parsed.in_reply_to,
      is_internal_note: false
    }

    case Message.insert_idempotent(attrs) do
      {:ok, _message} ->
        # Update last_customer_action_at
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        conversation
        |> Ecto.Changeset.change(last_customer_action_at: now)
        |> Repo.update!()

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp maybe_reactivate(conversation) do
    if conversation.state in [:dormant, :resolved] do
      conversation
      |> Conversation.state_changeset(:active)
      |> Repo.update!()
    else
      conversation
    end
  end

  # Urgency patterns - use word boundaries to reduce false positives
  # "down" is context-sensitive: "site is down" vs "scroll down"
  @urgent_patterns [
    ~r/\burgent\b/i,
    ~r/\bemergency\b/i,
    ~r/\bcritical\b/i,
    ~r/\boutage\b/i,
    # "down" with service context: "is down", "went down", "site down", "server down"
    ~r/\b(is|went|site|server|service|system|app|application|website)\s+down\b/i,
    ~r/\bdown\s*(for|since|again)\b/i
  ]
  @elevated_patterns [~r/\bimportant\b/i, ~r/\basap\b/i, ~r/\bpriority\b/i]

  defp detect_urgency(subject, body) do
    # Limit scan to first 2000 chars to avoid scanning huge email bodies
    text = String.slice((subject || "") <> " " <> (body || ""), 0, 2000)

    cond do
      Enum.any?(@urgent_patterns, &Regex.match?(&1, text)) -> :urgent
      Enum.any?(@elevated_patterns, &Regex.match?(&1, text)) -> :elevated
      true -> :normal
    end
  end
end

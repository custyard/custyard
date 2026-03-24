defmodule Custyard.Email.Processor do
  @moduledoc """
  Process inbound emails from Lettermint webhook.

  Handles email parsing, sender matching, thread detection, and Sieve header
  metadata extraction. Custom headers injected by Sieve rules can override
  auto-detected properties like urgency.
  """

  alias Custyard.{Repo, Conversation, Message, Scoring}
  alias Custyard.Email.{SenderMatcher, ThreadMatcher, SieveHeaderMapper}

  def process(params) do
    with {:ok, parsed} <- parse_payload(params),
         {:ok, org, contact} <- SenderMatcher.match(parsed.from),
         {:ok, conversation, is_new} <- find_or_create_conversation(parsed, org, contact) do
      # Create message
      create_message(conversation, parsed)

      # Trigger score recalc
      Scoring.calculate_and_cache(conversation.id)

      # Broadcast via PubSub - distinguish new vs updated
      event = if is_new, do: :conversation_created, else: :conversation_updated
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {event, conversation.id})

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversation:#{conversation.id}",
        {:message_added, conversation.id}
      )

      {:ok, Repo.reload!(conversation)}
    end
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
    # Try exact match first
    case headers[name] do
      nil ->
        # Fall back to case-insensitive lookup
        lowercase_name = String.downcase(name)

        Enum.find_value(headers, fn {k, v} ->
          if String.downcase(to_string(k)) == lowercase_name, do: v
        end)

      value ->
        value
    end
  end

  defp strip_html(nil), do: nil

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp find_or_create_conversation(parsed, org, contact) do
    # Try threading first
    case ThreadMatcher.find_thread(parsed) do
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
      urgency: detect_urgency(parsed.subject, parsed.body),
      last_customer_action_at: now
    }

    # Apply Sieve header overrides (e.g., X-Priority -> urgency)
    attrs = SieveHeaderMapper.merge_overrides(base_attrs, parsed.headers)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  defp create_message(conversation, parsed) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation.id,
      source: :email,
      sender_email: parsed.from,
      body: parsed.body,
      message_id: parsed.message_id,
      in_reply_to: parsed.in_reply_to,
      is_internal_note: false
    })
    |> Repo.insert!()

    # Update last_customer_action_at
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversation
    |> Ecto.Changeset.change(last_customer_action_at: now)
    |> Repo.update!()
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

  defp detect_urgency(subject, body) do
    text = String.downcase(subject <> " " <> body)

    cond do
      String.contains?(text, ["urgent", "emergency", "critical", "down", "outage"]) -> :urgent
      String.contains?(text, ["important", "asap", "priority"]) -> :elevated
      true -> :normal
    end
  end
end

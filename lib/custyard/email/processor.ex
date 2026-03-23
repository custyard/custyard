defmodule Custyard.Email.Processor do
  @moduledoc "Process inbound emails from Lettermint webhook"

  alias Custyard.{Repo, Conversation, Message, Scoring}
  alias Custyard.Email.{SenderMatcher, ThreadMatcher}

  def process(params) do
    with {:ok, parsed} <- parse_payload(params),
         {:ok, org, contact} <- SenderMatcher.match(parsed.from),
         {:ok, conversation} <- find_or_create_conversation(parsed, org, contact) do
      # Create message
      create_message(conversation, parsed)

      # Trigger score recalc
      Scoring.calculate_and_cache(conversation.id)

      # Broadcast update via PubSub
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:updated, conversation.id})

      {:ok, Repo.reload!(conversation)}
    end
  end

  defp parse_payload(params) do
    # Lettermint sends: from, to, subject, text, html, headers, attachments
    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject: params["subject"] || "(no subject)",
       body: params["text"] || strip_html(params["html"]) || "",
       message_id: get_header(params, "message-id"),
       in_reply_to: get_header(params, "in-reply-to"),
       references: get_header(params, "references")
     }}
  end

  defp get_header(params, name) do
    headers = params["headers"] || %{}
    headers[name] || headers[String.capitalize(name)]
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
        {:ok, conversation}

      :not_found ->
        # Create new conversation
        create_conversation(parsed, org, contact)
    end
  end

  defp create_conversation(parsed, org, contact) do
    %Conversation{}
    |> Conversation.changeset(%{
      organization_id: org.id,
      contact_id: contact && contact.id,
      subject: parsed.subject,
      state: :new,
      urgency: detect_urgency(parsed.subject, parsed.body),
      last_customer_action_at: DateTime.utc_now()
    })
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
    conversation
    |> Ecto.Changeset.change(last_customer_action_at: DateTime.utc_now())
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

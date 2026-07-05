defmodule Custyard.Email.ThreadHeaders do
  @moduledoc """
  Build threading headers for outbound email replies.

  This is the outbound counterpart to `Email.ThreadMatcher`, which matches
  inbound emails to conversations. This module constructs the `In-Reply-To`
  and `References` headers so email clients thread replies correctly.

  ## Header semantics (RFC 2822)

    - `In-Reply-To`: the Message-ID of the most recent message being replied to
    - `References`: space-separated list of all Message-IDs in the thread chain
  """

  alias Custyard.{Message, Repo}
  import Ecto.Query

  # Angle-bracketed msg-id with a single "@", free of whitespace and ASCII
  # control characters, so header values cannot smuggle CRLF (CWE-93).
  @msg_id_pattern ~r/^<[^\s<>@\x00-\x1F\x7F]+@[^\s<>@\x00-\x1F\x7F]+>$/

  @doc """
  Build threading headers for an outbound reply to a conversation.

  Queries email messages in the conversation (those with a `message_id` set),
  ordered by insertion time, and constructs the appropriate headers. Only
  values shaped like real RFC 5322 msg-ids are included (see
  `normalize_msg_id/1`), so synthetic webhook identifiers never leak into
  outbound mail.

  ## Options

    * `:exclude_message_id` - a Message-ID to omit from the chain (e.g. the
      outbound reply being composed, which must not reference itself)

  ## Returns

  A map with string keys suitable for passing to `Swoosh.Email.header/3`:

    - `"In-Reply-To"` - Message-ID of the most recent email in the thread
    - `"References"` - space-separated chain of all Message-IDs

  Returns an empty map if no email messages with message_ids exist in the
  conversation (e.g., a conversation started through the portal).

  ## Examples

      iex> headers = ThreadHeaders.for_conversation(conversation_id)
      %{"In-Reply-To" => "<abc@example.com>", "References" => "<abc@example.com> <def@example.com>"}

      iex> ThreadHeaders.for_conversation(portal_conversation_id)
      %{}
  """
  def for_conversation(conversation_id, opts \\ []) do
    message_ids =
      conversation_id
      |> message_ids_query(Keyword.get(opts, :exclude_message_id))
      |> Repo.all()
      |> Enum.map(&normalize_msg_id/1)
      |> Enum.reject(&is_nil/1)

    case message_ids do
      [] ->
        %{}

      ids ->
        %{
          "In-Reply-To" => List.last(ids),
          "References" => Enum.join(ids, " ")
        }
    end
  end

  # id breaks ties between rows sharing the same second-precision inserted_at
  defp message_ids_query(conversation_id, nil) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: not is_nil(m.message_id),
      order_by: [asc: m.inserted_at, asc: m.id],
      select: m.message_id
    )
  end

  defp message_ids_query(conversation_id, exclude_message_id) do
    from(m in message_ids_query(conversation_id, nil),
      where: m.message_id != ^exclude_message_id
    )
  end

  @doc """
  Normalize a stored message id for use in outbound threading headers.

  Returns the trimmed msg-id when it is shaped like a real RFC 5322 msg-id
  (angle-bracketed, containing "@", no whitespace or control characters),
  or `nil` otherwise. Webhook adapters store synthetic bracket-less ids
  (e.g. "zendesk-123@zendesk.webhook") that must not be emitted as email
  headers.
  """
  def normalize_msg_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if Regex.match?(@msg_id_pattern, trimmed), do: trimmed
  end

  def normalize_msg_id(_value), do: nil

  @doc """
  Apply threading headers to a Swoosh email.

  Convenience function that queries headers for the conversation and
  applies them to the email struct via `Swoosh.Email.header/3`.
  Accepts the same options as `for_conversation/2`.

  Returns the email unchanged if no threading headers are available.
  """
  def apply_to_email(%Swoosh.Email{} = email, conversation_id, opts \\ []) do
    conversation_id
    |> for_conversation(opts)
    |> Enum.reduce(email, fn {name, value}, acc ->
      Swoosh.Email.header(acc, name, value)
    end)
  end
end

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

  @doc """
  Build threading headers for an outbound reply to a conversation.

  Queries email messages in the conversation (those with a `message_id` set),
  ordered by insertion time, and constructs the appropriate headers.

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
  def for_conversation(conversation_id) do
    message_ids =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        where: not is_nil(m.message_id),
        order_by: [asc: m.inserted_at],
        select: m.message_id
      )
      |> Repo.all()

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

  @doc """
  Apply threading headers to a Swoosh email.

  Convenience function that queries headers for the conversation and
  applies them to the email struct via `Swoosh.Email.header/3`.

  Returns the email unchanged if no threading headers are available.
  """
  def apply_to_email(%Swoosh.Email{} = email, conversation_id) do
    for_conversation(conversation_id)
    |> Enum.reduce(email, fn {name, value}, acc ->
      Swoosh.Email.header(acc, name, value)
    end)
  end
end

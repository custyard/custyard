defmodule Custyard.Email.ThreadMatcher do
  @moduledoc """
  Match inbound email to existing conversation via threading headers.

  Thread matching is scoped by organization to prevent cross-organization
  information boundary violations. Without organization scoping, mailing list
  cross-posts or forwarded threads could cause messages to thread into the
  wrong organization's conversations.
  """

  alias Custyard.{Conversation, Message, Repo}
  import Ecto.Query

  @doc """
  Find an existing conversation thread for the given parsed email.

  Searches for matching message references (In-Reply-To header first,
  then References header) scoped to the specified organization.

  ## Parameters
    - parsed: Map containing `:in_reply_to` and `:references` headers
    - organization_id: The organization ID to scope the search to

  ## Returns
    - `{:ok, conversation}` if a matching thread is found
    - `:not_found` if no matching thread exists
  """
  def find_thread(parsed, organization_id) do
    # Try In-Reply-To first, then fall back to References header
    with :not_found <- find_by_message_id(parsed.in_reply_to, organization_id) do
      find_by_references(parsed.references, organization_id)
    end
  end

  defp find_by_message_id(nil, _organization_id), do: :not_found

  defp find_by_message_id(message_id, organization_id) do
    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.message_id == ^message_id,
        where: c.organization_id == ^organization_id,
        select: c,
        limit: 1

    case Repo.one(query) do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end

  defp find_by_references(nil, _organization_id), do: :not_found

  defp find_by_references(references, organization_id) do
    # References header can contain multiple message IDs
    message_ids = String.split(references, ~r/\s+/)

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.message_id in ^message_ids,
        where: c.organization_id == ^organization_id,
        select: c,
        limit: 1

    case Repo.one(query) do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end
end

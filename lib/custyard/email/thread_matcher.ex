defmodule Custyard.Email.ThreadMatcher do
  @moduledoc "Match inbound email to existing conversation via threading headers"

  alias Custyard.{Conversation, Message, Repo}
  import Ecto.Query

  def find_thread(parsed) do
    # Try In-Reply-To first, then fall back to References header
    with :not_found <- find_by_message_id(parsed.in_reply_to) do
      find_by_references(parsed.references)
    end
  end

  defp find_by_message_id(nil), do: :not_found

  defp find_by_message_id(message_id) do
    case Repo.get_by(Message, message_id: message_id) do
      nil ->
        :not_found

      message ->
        conversation = Repo.get!(Conversation, message.conversation_id)
        {:ok, conversation}
    end
  end

  defp find_by_references(nil), do: :not_found

  defp find_by_references(references) do
    # References header can contain multiple message IDs
    message_ids = String.split(references, ~r/\s+/)

    query =
      from m in Message,
        where: m.message_id in ^message_ids,
        limit: 1

    case Repo.one(query) do
      nil ->
        :not_found

      message ->
        conversation = Repo.get!(Conversation, message.conversation_id)
        {:ok, conversation}
    end
  end
end

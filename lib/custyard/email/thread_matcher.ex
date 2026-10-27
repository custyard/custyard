defmodule Custyard.Email.ThreadMatcher do
  @moduledoc """
  Match inbound email to existing conversation via threading headers.

  Thread matching is scoped by organization to prevent cross-organization
  information boundary violations. Without organization scoping, mailing list
  cross-posts or forwarded threads could cause messages to thread into the
  wrong organization's conversations.
  """

  alias Custyard.{Conversation, Message, Organization, Prospect, Repo}
  alias Custyard.Email.SenderMatcher
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
  def find_thread(parsed, organization_id, dedup_scope \\ nil) do
    # Try In-Reply-To first, then fall back to References header
    with :not_found <- find_by_message_id(parsed.in_reply_to, organization_id, dedup_scope) do
      find_by_references(parsed.references, organization_id, dedup_scope)
    end
  end

  @doc "Find an email thread by headers within the receiving tenant."
  def find_in_tenant(parsed, tenant_id) when is_integer(tenant_id) do
    with :not_found <- tenant_header_match([parsed[:in_reply_to]], tenant_id, parsed) do
      ids = if is_binary(parsed[:references]), do: String.split(parsed.references), else: []
      tenant_header_match(ids, tenant_id, parsed)
    end
  end

  def find_in_tenant(_parsed, _tenant_id), do: :not_found

  # A message can refer to several unrelated threads (mailing lists, forwards).
  # Ambiguity never silently chooses one customer's conversation.
  defp tenant_header_match(ids, tenant_id, parsed) do
    ids = Enum.filter(ids, &(is_binary(&1) and String.trim(&1) != ""))

    from(c in Conversation,
      join: m in Message,
      on: m.conversation_id == c.id,
      left_join: p in Prospect,
      on: p.conversation_id == c.id,
      where: c.tenant_id == ^tenant_id and m.message_id in ^ids,
      where: c.source in [:email, :lettermint, :public_intake, :portal],
      distinct: true,
      limit: 2,
      select: c
    )
    |> eligible_customers(parsed)
    |> Repo.all()
    |> case do
      [conversation] -> {:ok, conversation}
      [] -> :not_found
      _ambiguous -> :ambiguous
    end
  end

  # A public link has not established a customer relationship yet. Only the
  # captured prospect may turn its email reply into a customer thread; another
  # sender quoting its Message-ID must not claim that anonymous conversation.
  # Apply this restriction before LIMIT so ineligible public references cannot
  # hide a second eligible customer and turn an ambiguous match into a merge.
  defp eligible_customers(query, parsed) do
    case SenderMatcher.extract_email(parsed[:from]) do
      sender when is_binary(sender) ->
        where(
          query,
          [c, _m, p],
          not is_nil(c.organization_id) or
            (c.source == :public_intake and is_nil(p.revoked_at) and p.email == ^sender)
        )

      _ ->
        where(query, [c], not is_nil(c.organization_id))
    end
  end

  @doc """
  Conservative fallback for a reply whose threading headers were stripped.

  Requires a reply prefix, the same customer organization and an exact sender
  who has already participated. Only one recent matching conversation qualifies.
  New mail with a coincidentally identical subject does not merge.
  """
  def find_by_subject(parsed, organization_id, tenant_id) do
    with subject when is_binary(subject) <- parsed[:subject],
         true <- Regex.match?(~r/^\s*(?:re|aw|sv)\s*:/iu, subject),
         sender when is_binary(sender) <- SenderMatcher.extract_email(parsed[:from]),
         normalized when normalized != "" <- normalize_subject(subject) do
      cutoff = DateTime.utc_now() |> DateTime.add(-30 * 86_400)

      candidates =
        from(c in Conversation,
          join: o in Organization,
          on: o.id == c.organization_id,
          where: o.tenant_id == ^tenant_id and c.organization_id == ^organization_id,
          where: c.source in [:email, :lettermint] and c.updated_at >= ^cutoff,
          limit: 101,
          select: c
        )
        |> Repo.all()

      if length(candidates) > 100,
        do: :not_found,
        else:
          candidates
          |> Enum.filter(
            &(normalize_subject(&1.subject) == normalized and sender_participated?(&1, sender))
          )
          |> unique_match()
    else
      _ -> :not_found
    end
  end

  defp sender_participated?(conversation, sender) do
    conversation = Repo.preload(conversation, :contact)

    if conversation.contact && conversation.contact.email == sender do
      true
    else
      from(m in Message,
        where: m.conversation_id == ^conversation.id and m.source == :email,
        where: is_nil(m.deleted_at) and m.is_internal_note == false,
        where: is_nil(m.triage_class) or m.triage_class in [:customer, :operator_forward],
        select: m.sender_email
      )
      |> Repo.all()
      |> Enum.any?(&(SenderMatcher.extract_email(&1) == sender))
    end
  end

  defp normalize_subject(subject) when is_binary(subject) do
    subject
    |> String.replace(~r/^\s*(?:(?:re|aw|sv)\s*:\s*)+/iu, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_subject(_subject), do: ""

  defp unique_match([conversation]), do: {:ok, conversation}
  defp unique_match(_none_or_ambiguous), do: :not_found

  defp find_by_message_id(nil, _organization_id, _dedup_scope), do: :not_found

  defp find_by_message_id(message_id, organization_id, dedup_scope) do
    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.message_id == ^message_id,
        where: c.organization_id == ^organization_id,
        select: c,
        limit: 1

    case Repo.one(maybe_scope(query, dedup_scope)) do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end

  defp find_by_references(nil, _organization_id, _dedup_scope), do: :not_found

  defp find_by_references(references, organization_id, dedup_scope) do
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

    case Repo.one(maybe_scope(query, dedup_scope)) do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end

  defp maybe_scope(query, nil), do: query

  defp maybe_scope(query, dedup_scope) do
    where(query, [m, _c], m.dedup_scope == ^dedup_scope or is_nil(m.dedup_scope))
  end
end

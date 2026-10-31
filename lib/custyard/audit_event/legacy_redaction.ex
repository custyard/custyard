defmodule Custyard.AuditEvent.LegacyRedaction do
  @moduledoc false

  import Ecto.Query
  alias Custyard.{AuditEvent, Conversation, EmailAddress, Repo}

  # Contact erasure does not rewrite acknowledgment evidence or the history of
  # operator-account actions. Their actor IDs remain evidence of those actions.
  @events [
    :webhook_received,
    :webhook_processed,
    :webhook_error,
    :slug_released,
    :prospect_converted,
    :delivery_status_updated,
    :inbound_triaged
  ]
  @content_keys ~w(subject body html_body text_body message raw raw_payload reason)
  @redacted "[ERASED]"
  @postgres? Application.compile_env(:custyard, :repo_adapter, Custyard.Repo.Adapter) ==
               Ecto.Adapters.Postgres

  def redact(email, organization_id, owned_conversation_ids)
      when is_binary(email) and is_integer(organization_id) and is_list(owned_conversation_ids) do
    email = validated_email!(email)
    pattern = mailbox_pattern(email)

    organization_id
    |> scoped_query()
    |> Repo.all()
    |> Enum.reduce([], fn event, ids ->
      redact_event(event, email, pattern, owned_conversation_ids, ids)
    end)
    |> Enum.reverse()
  end

  defp validated_email!(email) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "audit redaction requires a transaction")

    email = EmailAddress.normalize(email)

    unless EmailAddress.valid?(email),
      do: raise(ArgumentError, "audit redaction requires a valid address")

    email
  end

  defp scoped_query(organization_id) do
    organization_conversations =
      from(c in Conversation, where: c.organization_id == ^organization_id, select: c.id)

    query =
      from(a in AuditEvent,
        where: a.event_type in ^@events,
        where:
          a.organization_id == ^organization_id or
            (is_nil(a.organization_id) and
               a.conversation_id in subquery(organization_conversations)),
        order_by: [asc: a.id]
      )

    if @postgres?, do: lock(query, "FOR UPDATE"), else: query
  end

  defp redact_event(event, email, pattern, owned_conversation_ids, ids) do
    erase_content? =
      event.conversation_id in owned_conversation_ids or subject_sender?(event.payload, email)

    payload = redact_value(event.payload, email, pattern, erase_content?)
    message_id = redact_value(event.message_id, email, pattern, false)

    if payload == event.payload and message_id == event.message_id do
      ids
    else
      {1, _} =
        Repo.update_all(from(a in AuditEvent, where: a.id == ^event.id),
          set: [payload: payload, message_id: message_id]
        )

      [event.id | ids]
    end
  end

  defp subject_sender?(payload, email) when is_map(payload) do
    Enum.any?(~w(sender_email email from), fn key ->
      case Map.get(payload, key) do
        item when is_binary(item) ->
          item = item |> String.trim() |> String.downcase()
          item == email or String.ends_with?(item, "<#{email}>")

        _ ->
          false
      end
    end)
  end

  defp subject_sender?(_payload, _email), do: false

  # Match a complete mailbox rather than erasing a different address whose
  # local part or domain happens to contain the subject's address. A terminal
  # sentence period remains punctuation; a following domain label does not.
  defp mailbox_pattern(email) do
    Regex.compile!(
      ~S"(?<![a-z0-9.!#$%&'*+/=?^_`{|}~@-])" <>
        Regex.escape(email) <> ~S"(?![a-z0-9@-]|\.[a-z0-9-])",
      "i"
    )
  end

  defp redact_value(value, email, pattern, erase_content?) when is_map(value) do
    erase_content? = erase_content? or subject_sender?(value, email)

    Map.new(value, fn {key, child} ->
      if erase_content? and key in @content_keys and not is_nil(child),
        do: {key, @redacted},
        else: {key, redact_value(child, email, pattern, erase_content?)}
    end)
  end

  defp redact_value(value, email, pattern, erase_content?) when is_list(value),
    do: Enum.map(value, &redact_value(&1, email, pattern, erase_content?))

  defp redact_value(value, _email, pattern, _erase_content?) when is_binary(value) do
    if Regex.match?(pattern, value), do: @redacted, else: value
  end

  defp redact_value(value, _email, _pattern, _erase_content?), do: value
end

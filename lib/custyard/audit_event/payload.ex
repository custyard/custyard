defmodule Custyard.AuditEvent.Payload do
  @moduledoc "Event-specific, typed payload minimization for persisted audit records."

  alias Custyard.Acknowledgments.Evidence

  @actor_keys ~w(actor operator_id)
  @channel_keys ~w(channel_id operator_id)
  @keys %{
    webhook_received: ~w(source timestamp),
    webhook_processed: ~w(source outcome conversation_id message_id),
    webhook_error: ~w(source outcome error_code),
    slug_released: ~w(slug status operator_id),
    prospect_converted: ~w(operator_id),
    operator_created: ~w(operator_id tenant_id role organization_id via),
    operator_removed:
      ~w(operator_id actor_operator_id tenant_id role organization_id via soft_deleted_message_ids),
    operator_tenant_access_granted:
      ~w(operator_id actor_operator_id tenant_id previous_organization_id role),
    acknowledgment_replayed:
      @actor_keys ++ ~w(source submission_id body_sha256 category attempt outcome),
    acknowledgment_binding_created:
      @actor_keys ++ ~w(source source_organization_id organization_id),
    delivery_status_updated:
      ~w(event delivery_id from to recipient_role recipient_from recipient_to reason_code status_code enhanced_status_code),
    channel_created: @channel_keys ++ ~w(provider ingress_kind),
    channel_updated: @channel_keys ++ ~w(changed),
    channel_deleted: @channel_keys,
    channel_state_changed: @channel_keys ++ ~w(from to),
    channel_token_rotated: @channel_keys ++ ~w(grace_hours),
    channel_token_revealed: @channel_keys,
    channel_verification_captured: @channel_keys ++ ~w(has_code has_link),
    channel_sending_domain_checked: @channel_keys ++ ~w(domain status),
    channel_quiet: @channel_keys ++ ~w(last_received_at quiet_after_hours),
    inbound_triaged: ~w(class channel_id route_id conversation_id),
    data_subject_erasure:
      ~w(erased sent_by_subject messages_erased attachments_removed conversations_retitled contacts_removed rejections_removed audit_events_redacted redacted_audit_event_ids)
  }
  @id_keys ~w(operator_id actor_operator_id organization_id tenant_id previous_organization_id channel_id route_id conversation_id message_id)
  @count_keys ~w(attempt grace_hours quiet_after_hours erased sent_by_subject messages_erased attachments_removed conversations_retitled contacts_removed rejections_removed audit_events_redacted)
  @status_values ~w(pending sending sent delivered bounced suppressed failed withheld draft pending_verification awaiting_first_message active paused revoked unclaimed claimed confirmed provisioned verified partially_verified failed_verification not_found)
  @known_fields ~w(public_address display_name provider ingress_kind state project_id reply_from sending_domain archive_copy attachment_limit_mb quiet_after_hours attention_bonus auto_response_handling imap_host imap_port imap_username imap_folder imap_password)
  @enums %{
    "actor" => ~w(operator cli mix console),
    "via" => ~w(cli mix boot console operator),
    "role" => ~w(super_admin admin agent),
    "provider" => ~w(proton google google_workspace other),
    "ingress_kind" => ~w(forward mx imap),
    "recipient_role" => ~w(to cc other),
    "reason_code" =>
      ~w(policy suppressed mailbox_full recipient_unknown mailbox_unavailable spam rate_limited temporary_failure blocked),
    "event" =>
      ~w(message.sent message.delivered message.hard_bounced message.failed message.policy_rejected message.suppressed),
    "category" =>
      ~w(message_too_large storage_unavailable source_mismatch invalid_json unmapped_organization invalid_evidence conflicting_submission processing_error),
    "class" =>
      ~w(customer_message operator_sent own_echo auto_response provider_notice unreadable no_channel paused revoked verification_captured),
    "outcome" =>
      ~w(started replayed empty changed updated ignored error invalid_config invalid_url unreachable timeout auth_failed access_refused tls_failed connection_failed channel_failed queue_missing precondition_failed operation_failed audit_failed unroutable publication_failed publication_rejected publication_unconfirmed),
    "error_code" => ~w(invalid_payload storage_unavailable processing_error)
  }

  @doc false
  def event_types, do: Map.keys(@keys)

  @doc "Unknown payload keys are omitted; invalid values of declared keys become nil."
  def minimize(payload, event) when is_map(payload) do
    allowed = Map.get(@keys, event, [])

    Enum.reduce(Map.to_list(payload), %{}, fn {key, value}, acc ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      if key in allowed, do: Map.put(acc, key, value(key, value, event)), else: acc
    end)
  end

  def minimize(_payload, _event), do: %{}

  defp value(_key, nil, _event), do: nil

  defp value(key, item, _event) when key in @id_keys,
    do: if(is_integer(item) and item > 0, do: item)

  defp value(key, item, _event) when key in @count_keys,
    do: if(is_integer(item) and item >= 0, do: item)

  defp value(key, items, _event)
       when key in ["soft_deleted_message_ids", "redacted_audit_event_ids"] and is_list(items),
       do: Enum.filter(items, &(is_integer(&1) and &1 > 0)) |> Enum.uniq()

  defp value("changed", items, _event) when is_list(items) do
    items
    |> Enum.map(fn item -> if is_atom(item), do: Atom.to_string(item), else: item end)
    |> Enum.filter(&(&1 in @known_fields))
    |> Enum.uniq()
  end

  defp value(key, item, _event) when key in ["has_code", "has_link"],
    do: if(is_boolean(item), do: item)

  defp value(key, item, _event) when key in ["timestamp", "last_received_at"] do
    if is_binary(item) and byte_size(item) <= 40 do
      case DateTime.from_iso8601(item) do
        {:ok, _, _} -> item
        _ -> nil
      end
    end
  end

  defp value("body_sha256", item, _event) do
    if is_binary(item) and byte_size(item) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, item),
      do: item
  end

  defp value("domain", item, _event) do
    if is_binary(item) and byte_size(item) <= 253 and
         Regex.match?(
           ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/i,
           item
         ),
       do: item
  end

  defp value("slug", item, _event) do
    if is_binary(item) and byte_size(item) <= 100 and
         Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, item),
       do: item
  end

  defp value("status_code", item, _event) when is_integer(item) and item in 100..599, do: item

  defp value("enhanced_status_code", item, _event) do
    if is_binary(item) and byte_size(item) <= 11 and
         Regex.match?(~r/\A[245]\.[0-9]{1,3}\.[0-9]{1,3}\z/, item),
       do: item
  end

  # These are contractual external identities, not arbitrary diagnostic text.
  # Preserve exact values accepted by the acknowledgment evidence validator.
  defp value(key, item, event)
       when key in ["source", "submission_id", "source_organization_id"] and
              event in [:acknowledgment_replayed, :acknowledgment_binding_created],
       do: if(Evidence.valid_identity?(item), do: item)

  defp value("source", item, _event),
    do:
      enum(
        item,
        ~w(email portal operator lettermint zendesk intercom slack public_intake unknown)
      )

  defp value("delivery_id", item, _event) do
    if is_binary(item) and byte_size(item) <= 255 and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, item),
       do: item
  end

  defp value(key, item, _event)
       when key in ["status", "from", "to", "recipient_from", "recipient_to"],
       do: enum(item, @status_values)

  defp value(key, item, _event), do: enum(item, Map.get(@enums, key, []))

  defp enum(item, allowed) do
    item = if is_atom(item), do: Atom.to_string(item), else: item
    if item in allowed, do: item
  end
end

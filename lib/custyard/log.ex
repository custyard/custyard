defmodule Custyard.Log do
  @moduledoc """
  Static operational events and typed metadata. The primary Logger filter
  minimizes every event before any console, error tracker or export handler.
  Unknown messages keep severity and code location, never rendered contents.
  """

  @known_exception_types [
    RuntimeError,
    ArgumentError,
    ArithmeticError,
    KeyError,
    MatchError,
    FunctionClauseError,
    UndefinedFunctionError,
    CaseClauseError,
    CondClauseError,
    BadFunctionError,
    BadArityError,
    ErlangError,
    Protocol.UndefinedError
  ]
  @known_exception_names Enum.map(@known_exception_types, &Atom.to_string/1)
  @filter_id :custyard_log_privacy
  @event_names ~w(
    acknowledgment_audit_record_failed
    acknowledgment_broker_unavailable
    acknowledgment_committed
    acknowledgment_configuration_missing
    acknowledgment_processing_failed
    acknowledgment_transport_insecure
    attachment_fetch_failed
    channel_audit_record_failed
    channel_mark_received_failed
    channel_quiet_email_failed
    channel_quiet_notification_failed
    channel_quiet_notification_stubbed
    channel_quiet_record_failed
    channel_verification_capture_failed
    claim_confirmation_email_accepted
    claim_confirmation_email_failed
    conversation_enrichment_failed
    conversation_enrichment_record_failed
    delivery_failure_notice_failed
    delivery_failure_notification_failed
    delivery_failure_notification_stubbed
    delivery_status_audit_record_failed
    dev_operator_created
    dev_operator_exists
    dev_operator_setup_failed
    dormancy_check_completed
    dormancy_check_failed
    email_header_decode_failed
    email_status_auth_rejected
    email_status_processing_failed
    email_status_secret_missing
    email_status_verification_skipped
    external_log
    fly_machine_count_unknown
    fly_mount_verification_failed
    health_check_failed
    http_request_completed
    http_request_started
    imap_database_unavailable
    imap_message_attempts_exhausted
    imap_message_not_imported
    imap_message_processing_failed
    imap_position_rebased
    inbound_rejection_record_failed
    inbound_route_action_unauthorized
    inbound_route_create_failed
    inbound_route_delete_failed
    inbound_route_sync_failed
    inbound_route_webhook_toggle_failed
    intake_arrival_email_accepted
    intake_arrival_email_failed
    intake_arrival_email_rate_limited
    intake_receipt_email_accepted
    intake_receipt_email_failed
    intake_source_unavailable
    intake_submission_accepted
    intake_submission_rejected
    lmtp_command_unrecognized
    lmtp_connection_rejected
    lmtp_ehlo_received
    lmtp_helo_received
    lmtp_mail_extension_received
    lmtp_mail_loop_detected
    lmtp_message_received
    lmtp_message_size_rejected
    lmtp_peer_format_invalid
    lmtp_processing_failed
    lmtp_rate_limit_cleanup_completed
    lmtp_rate_limit_cleanup_failed
    lmtp_rate_limit_exceeded
    lmtp_recipient_domain_rejected
    lmtp_recipient_extension_received
    lmtp_recipient_limit_exceeded
    lmtp_recipient_organization_mismatch
    lmtp_recipient_received
    lmtp_sender_received
    lmtp_server_started
    lmtp_session_terminated
    lmtp_starttls_completed
    lmtp_telemetry_event
    log_event_rejected
    logging_self_test
    message_source_defaulted
    neglect_check_completed
    neglect_check_failed
    neglect_notification_dispatched
    neglect_notification_failed
    neglect_notification_stubbed
    operator_account_created
    operator_account_removed
    operator_bootstrap_account_exists
    operator_bootstrap_environment_retained
    operator_bootstrap_failed
    operator_bootstrap_required
    operator_bootstrap_skipped
    operator_email_normalization_skipped
    operator_login_delivery_started
    operator_login_provider_accepted
    operator_login_provider_rejected
    operator_login_rejected
    operator_login_requested
    operator_login_skipped
    operator_login_succeeded
    operator_logout
    operator_placeholder_unroutable
    organization_deleted
    organization_deletion_failed
    organization_deletion_started
    outbound_delivery_failed
    outbound_delivery_interrupted
    outbound_delivery_withheld
    outbound_queue_scan_failed
    outbound_status_update_failed
    portal_path_already_prefixed
    prospect_conversion_audit_record_failed
    provider_delivery_organization_mismatch
    public_rate_limit_exceeded
    quiet_channel_check_completed
    quiet_channel_check_failed
    release_migration_failed
    release_repository_start_failed
    release_rollback_failed
    retention_sweep_completed
    retention_sweep_failed
    scoring_recalculation_completed
    scoring_recalculation_failed
    scoring_recalculation_started
    scoring_settings_database_failed
    scoring_settings_defaulted
    scoring_settings_unexpected_failure
    sender_organization_ambiguous
    sentry_handler_attach_failed
    slug_claim_expiry_completed
    slug_claim_expiry_failed
    slug_release_audit_record_failed
    tenant_notification_skipped
    triage_audit_record_failed
    unused_local_database_detected
    webhook_attachment_processing_failed
    webhook_audit_failed
    webhook_audit_record_failed
    webhook_audit_recorded
    webhook_auth_rejected
    webhook_notification_failed
    webhook_payload_rejected
    webhook_purpose_dropped
    webhook_purpose_failed
    webhook_purpose_start_failed
    webhook_secret_missing
    webhook_source_unconfigured
    webhook_verification_skipped
  )
  @events Enum.map(@event_names, &String.to_atom/1)
  @context_keys ~w(request_id operation_id parent_operation_id tenant_id organization_id operator_id channel_id route_id conversation_id message_id)a
  @integer_fields ~w(operator_id session_operator_id organization_id tenant_id conversation_id message_id channel_id inbound_channel_id route_id project_id audit_event_id slug_id contact_id source_id acknowledgment_id existing_organization_id new_organization_id conflicting_operator_id uid port count limit current_count max_size max_recipients actual_size declared_size size_bytes recipient_count received_count message_count messages_processed retry_after_ms retry_after_s attempt duration_ms deleted_count deleted_conversations deleted_messages deleted_attachments deleted_contacts deleted_operators deleted_routes deleted_channels organization_count quiet_after_hours conversations_deleted messages_deleted attachments_deleted contacts_deleted operators_deleted routes_deleted channels_deleted rejection_count rows affected_rows generation score dormant_count notification_count contacts_to_delete conversations_to_delete resolved_conversations orphaned_contacts orphaned_tasks channel_rejections channel_verifications channel_tokens attachment_files)a
  @boolean_fields ~w(enabled email_captured tls used_default configured accepted async tls_enabled)a
  @id_fields ~w(request_id operation_id parent_operation_id)a
  @reference_fields ~w(submission_ref source_ref receipt_ref)a
  @levels ~w(debug info notice warning error critical alert emergency)a
  @transport_reasons ~w(timeout closed econnrefused econnreset enetunreach ehostunreach nxdomain etimedout ssl_closed tls_alert certificate_expired unknown_ca from_not_set no_recipients no_recipient_email missing_credentials missing_project_credentials no_consent delivery_exception smtp_down)a
  @reason_values @transport_reasons ++
                   ~w(unknown_account no_organization missing_email email_rate_limited ip_rate_limited rate_limited no_consent exception validation_failed provider_response invalid_provider_response unclassified_error repository_unavailable database_unavailable constraint_error not_configured disabled not_found unauthorized forbidden invalid_signature missing_signature missing_secret unknown_source unknown_event unknown_message_source invalid_configuration invalid_payload invalid_header invalid_encoding oversized_message recipient_limit organization_mismatch unknown_recipient mail_loop ip_not_allowed temporary permanent invalid_response task_capacity no_matching_sender multiple_matches ambiguous manual own_echo no_channel tenant_not_found tenant_disabled missing_recipient delivery_error already_exist worker_exit invalid_context dropped other retry_scheduled acceptance_unknown invalid_domain capacity_exceeded no_operator_accounts no_staff sending_not_configured project_token_missing connection_not_found envelope_changed missing_raw_body missing_timestamp invalid_timestamp stale_timestamp invalid_signature_format normalization_collision invalid_utf8 invalid_or_expired_token eacces enoent eio enospc erofs enotdir eperm emfile enfile einval message_too_large storage_unavailable source_mismatch invalid_json unmapped_organization invalid_evidence conflicting_submission processing_error attachment_fetch_failed attachment_processing_failed channel_route_mismatch concurrent_update invalid_enabled_value invalid_url channel_failed connection_failed unreachable auth_failed access_refused tls_failed ack_failed subscription_failed subscription_cancelled publication_failed publication_unconfirmed publication_rejected unroutable)a
  @enums %{
    reason: @reason_values,
    outcome:
      ~w(started accepted rejected skipped succeeded failed completed updated ignored deferred withheld retrying unknown unavailable)a,
    source:
      ~w(email operator portal public_intake api webhook lettermint slack zendesk intercom lmtp imap cli boot scheduler inbound outbound internal broker test)a,
    mode: ~w(stub local test live enabled disabled development production active passive)a,
    receipt: ~w(sent skipped)a,
    role: ~w(super_admin admin agent operator customer contact prospect to cc bcc)a,
    stage:
      ~w(startup connect poll fetch parse dispatch persist deliver notify audit sweep retry shutdown weights intake_config neglect_thresholds)a,
    purpose:
      ~w(sender_matching enrichment notification audit attachments disambiguation login claim arrival receipt neglect quiet_channel delivery_failure)a,
    notification_level:
      ~w(info warning critical urgent high medium low neglect quiet delivery_failure)a,
    bucket:
      ~w(operator_login_ip operator_login_email intake_get intake_post conversation_mount conversation_reply email_capture claim_submit claim_confirm claim_email_send intake_arrival_email intake_receipt_email)a,
    action:
      ~w(create update delete enable disable release claim login logout add remove retry cancel revoke export erase)a,
    status:
      ~w(pending queued sending sent accepted delivered deferred bounced suppressed failed withheld unknown dormant active resolved closed)a,
    failure_kind: ~w(rejected unknown temporary permanent configuration transport provider)a,
    error_type: ~w(temporary permanent exception exit throw validation transport provider)a,
    limit_type: ~w(connection global recipient size ip email)a,
    method: ~w(GET HEAD POST PUT PATCH DELETE OPTIONS CONNECT TRACE),
    route: ~w(root health operator_login operator intake portal claim webhook other)a,
    provider: ~w(lettermint smtp sendgrid mailgun postmark local test unknown)a,
    event_type:
      ~w(acknowledgment_binding_created acknowledgment_replayed channel_created channel_deleted channel_quiet channel_sending_domain_checked channel_state_changed channel_token_revealed channel_token_rotated channel_updated channel_verification_captured data_subject_erasure delivery_status_updated inbound_triaged operator_created operator_removed operator_tenant_access_granted prospect_converted slug_released webhook_error webhook_processed webhook_received)a
  }
  @provider_codes ~w(validation_failed validation_error invalid_request invalid_payload invalid_api_token invalid_token unauthorized unauthenticated forbidden access_denied domain_not_verified sender_not_verified unverified_domain invalid_sender invalid_recipient invalid_email account_not_verified production_not_verified project_not_verified quota_exceeded rate_limit_exceeded too_many_requests insufficient_credits daily_limit_exceeded message_too_large invalid_attachment duplicate_request idempotency_conflict internal_error server_error service_unavailable sandbox_recipient_not_allowed)
  @validation_fields ~w(
    access_token_hash acknowledged_at actor_id actor_role actor_type address
    api_token archive_copy attachment_limit_mb attachments attention_bonus authentication
    batch_processing_expires_at batch_processing_token bcc body branding cached_score
    callback_token cc cc_addresses channel_id channels classification
    confirmation_token_hash confirmed_at contact contact_id contacts content
    content_id content_type conversation conversation_id conversations custom_domain
    dedup_scope default_channel default_channel_id deleted_at deleted_by_operator deleted_by_operator_id
    delivery_attempted_at delivery_error_code delivery_failure_kind delivery_payload_hash delivery_recipients_locked delivery_status
    description descriptor_hash display_name domain due_at email
    email_captured_at email_status email_status_at enabled endpoint_url event_type
    expires_at filename forwarded_by_email forwarded_by_operator forwarded_by_operator_id from
    from_address headers headline html html_body id
    imap_auth_failed_at imap_auth_failures imap_consecutive_failures imap_folder imap_host imap_last_error
    imap_last_polled_at imap_last_uid imap_message_attempts imap_password imap_password_ciphertext imap_port
    imap_uid_validity imap_username in_reply_to inbound_channel inbound_channel_id inbound_channels
    inbound_route inbound_route_id inbound_routes ingress_kind ingress_local ingress_token
    inserted_at intake_config intake_key intake_source_key intro_copy is_admin
    is_internal_note is_template key label label_id language
    last_customer_action_at last_neglect_notification last_operator_action_at last_received_at last_reply_accepted_at last_reply_delivered_at
    last_returning_reply_at last_signed_inbound_at last_status_event_at latest_received_conversation latest_received_conversation_id lettermint_custom_domain
    lettermint_custom_domain_verified_at lettermint_inbound_address lettermint_message_id lettermint_project_id lettermint_route_domain lettermint_route_id
    lettermint_webhook_id link_title link_url login_token login_token_expires_at logo_url
    message message_id messages metadata mode name
    neglect_thresholds normalized_name notify_on_reply operator_accounts organization organization_id
    organizations origin password password_hash paused_at payload
    portal_visible position previous_ingress_token previous_token_expires_at primary_color processing_expires_at
    processing_token progress project project_check_status project_checked_at project_id
    project_token_ciphertext project_type projects prospect provider provider_delivery_id
    public_address purpose questions quiet_after_hours quiet_notified_at received_at
    recipient recipient_statuses reply_evidence_after_message_id reply_from reply_to revoked_at
    role route route_type sandbox_result scheduled_at schema_version
    score_weights secondary_color sender_email sending_check_status sending_checked_at sending_domain
    sending_domain_checked_at sending_domain_status session_claim settings sha256 sieve_header_mappings
    singleton size skip_reason slug sniffed_type snoozed_until
    source source_organization_id spam_score start_date state statement_hash
    statement_key statement_text statement_version status status_at status_callback_token
    status_secret_ciphertext status_webhook_id storage_path subject submission_id suspect
    tag tags target_completion_date tasks team_token_ciphertext tenant
    tenant_id text tier title to to_addresses
    token triage_class updated_at urgency verification_captured_at verification_code
    verification_expires_at verification_link verified_at webhook_secret_ciphertext webhook_verified_at webhooks
  )

  @metadata_keys Enum.uniq(
                   @integer_fields ++
                     @boolean_fields ++
                     @id_fields ++
                     @reference_fields ++
                     Map.keys(@enums) ++
                     ~w(provider_status http_status provider_code validation_fields event origin error_code)a
                 )

  @doc false
  def metadata_keys, do: @metadata_keys

  @doc false
  def enum_values(field), do: Map.get(@enums, field, [])

  for level <- @levels do
    defmacro unquote(level)(event, fields \\ []) do
      unless event in @events do
        raise ArgumentError, "log event must be a registered literal atom"
      end

      level = unquote(level)

      quote do
        require Logger

        Logger.log(
          unquote(level),
          unquote(Atom.to_string(event)),
          Map.put(
            Custyard.Log.sanitize_metadata(unquote(fields)),
            :custyard_event,
            unquote(event)
          )
        )
      end
    end
  end

  @doc "Installs privacy before storage validation, Repo, jobs, and Sentry handlers."
  def install! do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      _ -> raise "Could not install log privacy filter"
    end

    case :logger.set_handler_config(:default, :formatter, {Custyard.Log.Formatter, %{}}) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      _ -> raise "Could not configure structured console logging"
    end
  end

  @doc false
  def filter(%{level: level, meta: metadata} = event, _config) when level in @levels do
    fields = sanitize_metadata(metadata)
    location = safe_location(metadata)
    origin = fields[:origin] || safe_origin(location[:mfa])
    fields = if origin, do: Map.put(fields, :origin, origin), else: fields

    {name, fields} =
      case Map.get(metadata, :custyard_event) do
        name when name in @events ->
          {name, fields}

        _ ->
          {:external_log, Map.merge(fields, report_failure(Map.get(event, :msg)))}
      end

    safe_metadata =
      runtime_metadata(metadata)
      |> Map.merge(location)
      |> Map.merge(fields)
      |> Map.merge(%{service: :custyard, schema_version: 1, custyard_event: name})

    %{level: level, msg: {:string, Atom.to_string(name)}, meta: safe_metadata}
  rescue
    _ -> fallback_event(event)
  catch
    _, _ -> fallback_event(event)
  end

  def filter(event, _config), do: fallback_event(event)

  defp runtime_metadata(metadata) do
    time =
      if is_integer(metadata[:time]), do: metadata[:time], else: System.system_time(:microsecond)

    domain =
      case metadata[:domain] do
        values when is_list(values) ->
          Enum.filter(
            Enum.take(values, 16),
            &(&1 in [:sentry, :otp, :sasl, :elixir, :bandit, :cowboy, :phoenix, :ecto])
          )

        _ ->
          []
      end

    Enum.reduce([:pid, :gl], %{time: time, domain: domain}, fn key, acc ->
      if is_pid(metadata[key]), do: Map.put(acc, key, metadata[key]), else: acc
    end)
  end

  defp fallback_event(source) do
    domain =
      case source do
        %{meta: %{domain: values}} -> if sentry_domain?(values, 0), do: [:sentry], else: []
        _ -> []
      end

    %{
      level: :error,
      msg: {:string, "log_event_rejected"},
      meta: %{
        time: System.system_time(:microsecond),
        service: :custyard,
        schema_version: 1,
        custyard_event: :log_event_rejected,
        domain: domain
      }
    }
  end

  defp sentry_domain?(_values, depth) when depth > 16, do: false
  defp sentry_domain?([:sentry | _], _depth), do: true
  defp sentry_domain?([_ | rest], depth), do: sentry_domain?(rest, depth + 1)
  defp sentry_domain?(_values, _depth), do: false

  @doc "Drops unknown fields and values, retaining only JSON-safe typed metadata."
  def sanitize_metadata(fields) when is_list(fields) do
    if Keyword.keyword?(fields), do: fields |> Map.new() |> sanitize_metadata(), else: %{}
  end

  def sanitize_metadata(fields) when is_map(fields) do
    Enum.reduce(fields, %{}, fn {key, value}, safe ->
      key = known_key(key)

      case safe_value(key, value) do
        nil -> safe
        sanitized -> Map.put(safe, key, sanitized)
      end
    end)
  rescue
    _ -> %{}
  end

  def sanitize_metadata(_fields), do: %{}

  defp known_key(key) when is_atom(key), do: key

  defp known_key(key) when is_binary(key) do
    Enum.find(@metadata_keys, &(Atom.to_string(&1) == key))
  end

  defp known_key(_key), do: nil

  defp safe_value(key, value)
       when key in @integer_fields and is_integer(value) and value >= 0 and
              value <= 9_223_372_036_854_775_807,
       do: value

  defp safe_value(key, value) when key in @boolean_fields and is_boolean(value), do: value

  defp safe_value(key, value)
       when key in [:provider_status, :http_status] and is_integer(value) and value in 100..599,
       do: value

  defp safe_value(key, value) when key in @id_fields and is_binary(value) do
    if byte_size(value) in 20..64 and String.valid?(value) and
         Regex.match?(~r/\A[A-Za-z0-9_-]{20,64}\z/, value),
       do: value
  end

  defp safe_value(key, value) when key in @reference_fields and is_binary(value) do
    if byte_size(value) == 64 and String.valid?(value) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
       do: value
  end

  defp safe_value(:error_code, value)
       when value in ~w(no_recipient_email from_not_set not_configured sending_not_configured project_token_missing connection_not_found envelope_changed timeout closed econnrefused nxdomain delivery_error provider_response),
       do: value

  defp safe_value(:error_code, "http_" <> code = value) do
    if byte_size(code) == 3 do
      case Integer.parse(code) do
        {status, ""} when status in 100..599 -> value
        _ -> nil
      end
    end
  end

  defp safe_value(:event, value), do: safe_event_name(value)
  defp safe_value(:origin, value), do: safe_origin(value)
  defp safe_value(:provider_code, value) when value in @provider_codes, do: value

  defp safe_value(:validation_fields, value) when is_list(value) do
    value
    |> Enum.take(64)
    |> Enum.filter(&(&1 in @validation_fields))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(16)
  end

  defp safe_value(:error_type, module) when is_atom(module) do
    if exception_module?(module),
      do: Atom.to_string(module),
      else: enum_value(:error_type, module)
  end

  defp safe_value(:error_type, value) when value in @known_exception_names, do: value

  defp safe_value(:error_type, value) when is_binary(value) do
    # Preserve declared categories and names of already loaded exception modules.
    module = String.to_existing_atom(value)
    if exception_module?(module), do: value, else: enum_value(:error_type, value)
  rescue
    _ -> enum_value(:error_type, value)
  end

  defp safe_value(key, value), do: enum_value(key, value)

  defp exception_module?(module),
    do: module in @known_exception_types or function_exported?(module, :exception, 1)

  defp enum_value(key, value) do
    case Map.get(@enums, key) do
      nil ->
        nil

      allowed ->
        Enum.find_value(allowed, fn candidate ->
          if value == candidate or value == to_string(candidate), do: to_string(candidate)
        end)
    end
  end

  @doc "Bounded diagnostics without exception messages, response bodies or headers."
  def failure(reason) do
    classify_failure(reason, 0)
  rescue
    _ -> [reason: :unclassified_error]
  catch
    _, _ -> [reason: :unclassified_error]
  end

  defp classify_failure(_reason, depth) when depth > 4, do: [reason: :unclassified_error]

  defp classify_failure({:api_error, status, body}, depth) when is_integer(status),
    do: classify_failure({status, body}, depth + 1)

  defp classify_failure({:provider_status, status}, depth) when status in 100..599 do
    classify_failure({status, nil}, depth + 1)
  end

  defp classify_failure({:parse_failed, reason}, depth), do: classify_failure(reason, depth + 1)

  defp classify_failure({kind, reason}, depth) when kind in [:exit, :throw] do
    reason |> classify_failure(depth + 1) |> Keyword.put_new(:error_type, kind)
  end

  defp classify_failure({:request_failed, reason}, depth), do: classify_failure(reason, depth + 1)
  defp classify_failure({:error, reason}, depth), do: classify_failure(reason, depth + 1)

  defp classify_failure({status, response}, _depth)
       when is_integer(status) and status in 100..599 do
    [reason: :provider_response, provider_status: status] ++ provider_fields(response)
  end

  defp classify_failure(%Ecto.Changeset{errors: errors}, _depth) do
    fields =
      for {field, _error} <- errors,
          is_atom(field),
          name = Atom.to_string(field),
          name in @validation_fields,
          do: name

    [reason: :validation_failed, validation_fields: Enum.take(Enum.uniq(fields), 16)]
  end

  defp classify_failure(%{__struct__: module, __exception__: true}, _depth)
       when is_atom(module) do
    if exception_module?(module),
      do: [reason: :exception, error_type: module],
      else: [reason: :unclassified_error]
  end

  defp classify_failure({%{__struct__: module, __exception__: true} = error, _stack}, depth)
       when is_atom(module) do
    classify_failure(error, depth + 1)
  end

  defp classify_failure(reason, _depth) when reason in @transport_reasons, do: [reason: reason]

  defp classify_failure({reason, _details}, _depth) when reason in @reason_values,
    do: [reason: reason]

  defp classify_failure(reason, _depth) when reason in @reason_values, do: [reason: reason]
  defp classify_failure("unauthorized", _depth), do: [reason: :unauthorized]
  defp classify_failure("no secret configured", _depth), do: [reason: :missing_secret]
  defp classify_failure("missing signature header", _depth), do: [reason: :missing_signature]
  defp classify_failure("invalid signature", _depth), do: [reason: :invalid_signature]

  defp classify_failure("invalid signature format", _depth),
    do: [reason: :invalid_signature_format]

  defp classify_failure("missing raw body", _depth), do: [reason: :missing_raw_body]
  defp classify_failure("missing timestamp", _depth), do: [reason: :missing_timestamp]
  defp classify_failure("invalid timestamp", _depth), do: [reason: :invalid_timestamp]
  defp classify_failure("invalid timestamp format", _depth), do: [reason: :invalid_timestamp]
  defp classify_failure("stale timestamp", _depth), do: [reason: :stale_timestamp]

  defp classify_failure("stale timestamp - request may be a replay attack", _depth),
    do: [reason: :stale_timestamp]

  defp classify_failure(_reason, _depth), do: [reason: :unclassified_error]

  defp provider_fields(response) when is_map(response) do
    error = field(response, :error)
    nested = if is_map(error), do: error, else: %{}
    code = field(response, :code) || field(nested, :code) || error
    fields = field(response, :errors) || field(nested, :details) || field(nested, :errors)
    provider_code_fields(code) ++ provider_validation_fields(fields)
  end

  defp provider_fields(_response), do: []

  defp field(map, key), do: Map.get(map, Atom.to_string(key), Map.get(map, key))

  defp provider_code_fields(code) when code in @provider_codes, do: [provider_code: code]
  defp provider_code_fields(_code), do: []

  defp provider_validation_fields(fields) when is_map(fields) do
    fields =
      fields
      |> Map.keys()
      |> Enum.flat_map(&validation_field/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(16)

    if fields == [], do: [], else: [validation_fields: fields]
  end

  defp provider_validation_fields(_fields), do: []

  defp validation_field(field) when is_atom(field), do: validation_field(Atom.to_string(field))

  defp validation_field(field) when is_binary(field) and byte_size(field) < 128 do
    case String.split(field, ".", parts: 2) do
      [root | _] when root in @validation_fields -> [root]
      _ -> []
    end
  end

  defp validation_field(_field), do: []

  @doc "Opaque external identifiers only; hashes remain restricted pseudonymous data."
  def reference(value) when is_binary(value) and byte_size(value) <= 4096,
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  def reference(_value), do: nil

  def new_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  def context, do: Logger.metadata() |> sanitize_metadata() |> Map.take(@context_keys)

  @doc "Capture safe context now; restore it in an asynchronous child."
  def task(fun, fields \\ []) when is_function(fun, 0) do
    parent = context()
    fn -> with_context(parent, fn -> operation(fields, fun) end) end
  end

  def operation(fields, fun) when is_function(fun, 0) do
    parent_id = Map.get(context(), :operation_id)

    fields =
      fields
      |> sanitize_metadata()
      |> Map.put(:operation_id, new_id())
      |> Map.put(:parent_operation_id, parent_id)

    with_context(fields, fun)
  end

  def with_context(fields, fun) when is_function(fun, 0) do
    previous = Logger.metadata()

    Logger.reset_metadata(
      Map.to_list(Map.merge(sanitize_metadata(previous), sanitize_metadata(fields)))
    )

    try do
      fun.()
    after
      Logger.reset_metadata(previous)
    end
  end

  @doc "A registered machine event name, never a free-form message."
  def safe_event_name(value) when value in @events, do: Atom.to_string(value)
  def safe_event_name(value) when value in @event_names, do: value
  def safe_event_name(_value), do: nil

  @doc "A loaded module and existing code symbol, without arguments or source paths."
  def safe_origin({module, function, arity})
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity in 0..255 do
    if :code.is_loaded(module) != false and
         Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_!?]{0,79}\z/, Atom.to_string(function)) do
      "#{module}.#{function}/#{arity}"
    end
  end

  def safe_origin(value) when is_binary(value) and byte_size(value) < 255 do
    case Regex.run(~r/\A([A-Za-z0-9_.]+)\.([a-zA-Z_][a-zA-Z0-9_!?]{0,79})\/(\d{1,3})\z/, value) do
      [_, module, function, arity] ->
        safe_origin(
          {String.to_existing_atom(module), String.to_existing_atom(function),
           String.to_integer(arity)}
        )

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def safe_origin(_value), do: nil

  defp safe_location(%{mfa: {module, function, arity}} = metadata)
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 and
              arity <= 255 do
    location =
      if safe_origin({module, function, arity}), do: %{mfa: {module, function, arity}}, else: %{}

    if is_integer(metadata[:line]) and metadata[:line] > 0,
      do: Map.put(location, :line, metadata[:line]),
      else: location
  end

  defp safe_location(_metadata), do: %{}

  defp report_failure({:report, report}) do
    case crash_details(report) do
      {reason, stack} ->
        fields = reason |> crash_reason() |> sanitize_metadata()

        case crash_origin(stack) do
          nil -> fields
          origin -> Map.put(fields, :origin, origin)
        end

      nil ->
        %{}
    end
  end

  defp report_failure(_message), do: %{}

  defp crash_details(%{label: {:proc_lib, :crash}, report: [own_report | _]}),
    do: crash_details(own_report)

  defp crash_details(%{reason: {reason, stack}}) when is_list(stack), do: {reason, stack}
  defp crash_details(%{reason: reason}), do: {reason, []}

  defp crash_details(%{error_info: {_kind, reason, stack}}) when is_list(stack),
    do: {reason, stack}

  defp crash_details(report) when is_list(report) do
    if Keyword.keyword?(report) do
      keyword_crash_details(report)
    else
      case report do
        [own_report | _] -> crash_details(own_report)
        _ -> nil
      end
    end
  end

  defp crash_details(_report), do: nil

  defp keyword_crash_details(report) do
    case Keyword.get(report, :error_info) do
      {_kind, reason, stack} when is_list(stack) ->
        {reason, stack}

      _ ->
        case Keyword.fetch(report, :reason) do
          {:ok, reason} -> {reason, []}
          :error -> nil
        end
    end
  end

  defp crash_reason({:badkey, _key}), do: [reason: :exception, error_type: KeyError]
  defp crash_reason({:badkey, _key, _value}), do: [reason: :exception, error_type: KeyError]
  defp crash_reason({:badmatch, _value}), do: [reason: :exception, error_type: MatchError]
  defp crash_reason(:badarg), do: [reason: :exception, error_type: ArgumentError]
  defp crash_reason(:badarith), do: [reason: :exception, error_type: ArithmeticError]
  defp crash_reason(:undef), do: [reason: :exception, error_type: UndefinedFunctionError]
  defp crash_reason(:function_clause), do: [reason: :exception, error_type: FunctionClauseError]
  defp crash_reason(reason), do: failure(reason)

  defp crash_origin(stack) do
    origins =
      stack
      |> Enum.take(32)
      |> Enum.flat_map(fn
        {module, function, arity, _location} when is_integer(arity) ->
          List.wrap(safe_origin({module, function, arity}))

        {module, function, arguments, _location} when is_list(arguments) ->
          List.wrap(safe_origin({module, function, arguments |> Enum.take(256) |> length()}))

        _ ->
          []
      end)

    Enum.find(origins, &String.starts_with?(&1, "Elixir.Custyard")) || List.first(origins)
  end
end

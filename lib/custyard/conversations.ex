defmodule Custyard.Conversations do
  @moduledoc """
  Context for conversation queries and operations.
  """

  alias Custyard.{
    Contact,
    Conversation,
    EmailAddress,
    Message,
    OperatorAccess,
    OperatorAccount,
    Repo
  }

  alias Custyard.Email.{OutboundQueue, SenderMatcher}
  alias Custyard.InboundChannels
  import Ecto.Query

  @doc """
  List conversations for the operator attention queue.
  Excludes resolved and currently-snoozed conversations, ordered by cached_score descending.
  Returns list of `%{conversation: conversation, message_count: count}` maps.

  Options:
    - :filter - state filter ("all", "new", "active", "waiting", "dormant", "snoozed")
    - :organization_id - scope to a specific organization (nil for all - super_admin only).
      Org-scoped results also include conversations without an organization
      (unlinked prospects) — they are visible to all operator roles, matching
      `Custyard.Authorization.can_access_conversation?/2`.
  """
  def list_for_attention_queue(opts \\ []) do
    filter = Keyword.get(opts, :filter, "all")
    organization_id = Keyword.get(opts, :organization_id)
    now = DateTime.utc_now()

    message_count_subquery =
      from m in Message,
        group_by: m.conversation_id,
        select: %{conversation_id: m.conversation_id, count: count(m.id)}

    query =
      from c in Conversation,
        # Left join: disambiguation/public-intake conversations have nil organization_id
        left_join: o in assoc(c, :organization),
        left_join: ct in assoc(c, :contact),
        # Prospect preload feeds reply_channel/1 without N+1 queries
        left_join: p in assoc(c, :prospect),
        left_join: ch in assoc(c, :inbound_channel),
        left_join: mc in subquery(message_count_subquery),
        on: mc.conversation_id == c.id,
        # Exclude resolved conversations (snoozed filter handled separately)
        where: c.state != :resolved,
        order_by: [desc: c.cached_score],
        preload: [organization: o, contact: ct, prospect: p, inbound_channel: ch],
        select: %{conversation: c, message_count: coalesce(mc.count, 0)}

    query
    |> apply_organization_filter(organization_id)
    |> apply_snooze_filter(filter, now)
    |> apply_state_filter(filter)
    |> Repo.all()
  end

  # Filter for snoozed conversations - only show snoozed when explicitly filtered
  defp apply_snooze_filter(query, "snoozed", now) do
    from c in query, where: c.snoozed_until >= ^now
  end

  defp apply_snooze_filter(query, _filter, now) do
    from c in query, where: is_nil(c.snoozed_until) or c.snoozed_until < ^now
  end

  defp apply_organization_filter(query, nil), do: query

  # Org-scoped operators also see conversations without an organization
  # (unlinked prospects); see list_for_attention_queue/1.
  defp apply_organization_filter(query, org_id) when is_integer(org_id) do
    from c in query, where: c.organization_id == ^org_id or is_nil(c.organization_id)
  end

  defp apply_state_filter(query, "all"), do: query
  defp apply_state_filter(query, "new"), do: from(c in query, where: c.state == :new)
  defp apply_state_filter(query, "active"), do: from(c in query, where: c.state == :active)
  defp apply_state_filter(query, "waiting"), do: from(c in query, where: c.state == :waiting)
  defp apply_state_filter(query, "dormant"), do: from(c in query, where: c.state == :dormant)
  defp apply_state_filter(query, _), do: query

  @doc """
  List all conversations that are currently at or past neglect thresholds.
  Returns conversations with organization preloaded, excluding resolved and snoozed.

  Options:
    - :organization_id - scope to a specific organization (nil for all - super_admin only)
  """
  def list_neglected(opts \\ []) do
    organization_id = Keyword.get(opts, :organization_id)
    now = DateTime.utc_now()

    from(c in Conversation,
      # Left join: disambiguation conversations have nil organization_id
      left_join: o in assoc(c, :organization),
      left_join: ct in assoc(c, :contact),
      where: c.state != :resolved,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
      # Order by org name (nil sorts first), then by score
      order_by: [asc_nulls_first: o.name, desc: c.cached_score],
      preload: [organization: o, contact: ct]
    )
    |> apply_organization_filter(organization_id)
    |> Repo.all()
  end

  @doc """
  List conversations for an organization's portal view.

  Options:
    - :include_resolved - include resolved conversations (default: false)
    - :contact_id - filter to only this contact's conversations (default: nil = all)
  """
  def list_for_organization(org_id, opts \\ []) do
    include_resolved = Keyword.get(opts, :include_resolved, false)
    contact_id = Keyword.get(opts, :contact_id)

    query =
      from c in Conversation,
        where: c.organization_id == ^org_id,
        order_by: [desc: c.inserted_at],
        preload: [:contact]

    query =
      if contact_id do
        from c in query, where: c.contact_id == ^contact_id
      else
        query
      end

    query =
      if include_resolved do
        query
      else
        from c in query, where: c.state != :resolved
      end

    Repo.all(query)
  end

  @doc """
  Get a single conversation by ID.
  """
  def get_conversation(id) do
    Repo.get(Conversation, id)
  end

  @doc """
  Get a single conversation by ID or raise.
  """
  def get_conversation!(id) do
    Repo.get!(Conversation, id)
  end

  @doc """
  Get conversation for organization with ownership check.
  Returns `{:ok, conversation}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def get_conversation_for_organization(id, org_id) do
    case Repo.get(Conversation, id) |> Repo.preload([:contact, :organization]) do
      nil ->
        {:error, :not_found}

      conversation ->
        if conversation.organization_id == org_id do
          {:ok, conversation}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Get conversation with preloaded messages and associations.
  WARNING: No org scoping - use get_with_messages_for_organization/2 for user-facing requests.
  """
  def get_with_messages(id) do
    Repo.get!(Conversation, id)
    |> Repo.preload([
      :organization,
      :contact,
      # Feeds reply_channel/1 and reply_deliverable?/1 without extra queries
      :prospect,
      :tasks,
      # Channel badge and the reply From identity (spec-inbound-channels D3)
      inbound_channel: :inbound_route,
      messages: {from(m in Message, order_by: m.inserted_at), [:attachments]}
    ])
  end

  @doc """
  Clear or set the triage suspect flag on a conversation (operator action).
  """
  def set_suspect(%Conversation{} = conversation, suspect?) when is_boolean(suspect?) do
    with {:ok, updated} <-
           conversation |> Conversation.suspect_changeset(suspect?) |> Repo.update() do
      broadcast_to_org(updated.organization_id, {:conversation_updated, updated.id})

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversations",
        {:conversation_updated, updated.id}
      )

      {:ok, updated}
    end
  end

  @doc """
  Get conversation with preloaded messages, scoped to organization.
  Returns `{:ok, conversation}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  Use this for user-facing requests to prevent IDOR.
  """
  def get_with_messages_for_organization(id, org_id) do
    case Repo.get(Conversation, id) do
      nil ->
        {:error, :not_found}

      conversation ->
        if conversation.organization_id == org_id do
          preloaded =
            Repo.preload(conversation, [
              :organization,
              :contact,
              :tasks,
              messages: from(m in Message, order_by: m.inserted_at)
            ])

          {:ok, preloaded}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Get public messages for a conversation (excludes internal notes).
  """
  def list_public_messages(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.is_internal_note == false,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Count messages for a conversation.
  """
  def count_messages(conversation_id) do
    from(m in Message, where: m.conversation_id == ^conversation_id, select: count(m.id))
    |> Repo.one()
  end

  @doc """
  Create a new conversation.
  """
  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update conversation state.
  """
  def update_state(conversation, new_state) do
    conversation
    |> Conversation.state_changeset(new_state)
    |> Repo.update()
  end

  @doc """
  Snooze a conversation until the given datetime.
  """
  def snooze(conversation, until) do
    conversation
    |> Conversation.snooze_changeset(until)
    |> Repo.update()
  end

  @doc """
  Un-snooze a conversation, making it appear in the attention queue again.
  """
  def unsnooze(conversation) do
    conversation
    |> Conversation.snooze_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Update conversation with allowed changes (goes through changeset for validation).
  Note: cached_score and last_neglect_notification are not allowed - they are computed fields.
  """
  def update_conversation(conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically transition a conversation from one state to another.

  Uses a conditional UPDATE to prevent race conditions when multiple operators
  access the same conversation simultaneously. Only updates if the conversation
  is still in the expected `from_state`.

  Returns:
    - `{:ok, updated_conversation}` if the transition succeeded
    - `{:ok, :already_transitioned}` if conversation was already in a different state
    - `{:error, changeset}` if the update failed for other reasons

  ## Examples

      # Transition from :new to :active when operator views
      transition_state(conversation, :new, :active, last_operator_action_at: now)

  """
  def transition_state(conversation, from_state, to_state, additional_attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Keyword.merge([state: to_state, updated_at: now], additional_attrs)

    # Build the update query with a WHERE condition on current state
    query =
      from c in Conversation,
        where: c.id == ^conversation.id and c.state == ^from_state

    case Repo.update_all(query, set: attrs) do
      {1, _} ->
        # Successfully updated - reload to get fresh data
        {:ok, Repo.get!(Conversation, conversation.id) |> Repo.preload([:organization, :contact])}

      {0, _} ->
        # No rows updated - state was already different, check current state
        current =
          Repo.get!(Conversation, conversation.id) |> Repo.preload([:organization, :contact])

        if current.state == to_state do
          # Already in target state - another operator transitioned it first
          {:ok, :already_transitioned}
        else
          # In some other state - return the current conversation
          {:ok, :already_transitioned}
        end
    end
  end

  @doc """
  Reload a conversation from the database.
  """
  def reload!(conversation) do
    Repo.reload!(conversation)
  end

  @doc """
  Derive the reply channel for a conversation.

  Returns `{:contact, email}` when the linked contact has an email (always
  preferred), `{:prospect, email}` when a prospect captured an email and
  conversation access has not been revoked, and `:none` otherwise.

  The "no reply channel" state is derived, never stored — capturing an email
  clears it with zero clearing code. Contact and prospect are preloaded only
  when not already loaded, so preloading callers (the attention queue) pay no
  extra queries.
  """
  def reply_channel(%Conversation{} = conversation) do
    conversation = preload_reply_channel_assocs(conversation)

    cond do
      email = contact_email(conversation.contact) -> {:contact, email}
      email = prospect_email(conversation.prospect) -> {:prospect, email}
      true -> :none
    end
  end

  defp preload_reply_channel_assocs(conversation) do
    if Ecto.assoc_loaded?(conversation.contact) and Ecto.assoc_loaded?(conversation.prospect) do
      conversation
    else
      Repo.preload(conversation, [:contact, :prospect])
    end
  end

  defp contact_email(%Custyard.Contact{email: email}) when is_binary(email) and email != "",
    do: email

  defp contact_email(_contact), do: nil

  # Prospect email counts only while conversation access is not revoked
  defp prospect_email(%Custyard.Prospect{email: email, revoked_at: nil})
       when is_binary(email) and email != "",
       do: email

  defp prospect_email(_prospect), do: nil

  @doc """
  Classify how an operator reply on this conversation would be delivered.

  Returns one of:

    * `:contact` — the linked contact has an email; delivers unconditionally
      (established-customer path)
    * `:prospect_opted_in` — a prospect email was captured with the
      reply-notification opt-in; delivers
    * `:prospect_no_consent` — a prospect email was captured but the prospect
      has not opted into email replies; the consent-advisory state
    * `:none` — no recipient at all (no email captured, or conversation access
      revoked)

  The operator UI keys the consent advisory on `:prospect_no_consent`
  specifically — the `:none` states are conveyed by the reply-channel badge,
  not the opt-in wording.

  Callers must pass a `conversation` with fresh `:contact`/`:prospect`
  associations. If they are already `Ecto.assoc_loaded?`, this function reuses
  them as-is rather than re-reading from the database — a stale preload (e.g.
  a prospect's `notify_on_reply` flipped after it was loaded) silently
  produces a stale consent decision.
  """
  def reply_delivery(%Conversation{} = conversation) do
    conversation = preload_reply_channel_assocs(conversation)

    case reply_channel(conversation) do
      {:contact, _email} ->
        :contact

      {:prospect, _email} ->
        if conversation.prospect.notify_on_reply,
          do: :prospect_opted_in,
          else: :prospect_no_consent

      :none ->
        :none
    end
  end

  @doc """
  Whether an operator reply on this conversation will be emailed.

  Contact recipients deliver unconditionally — the established-customer path,
  including when a captured prospect email matched an existing contact and the
  conversation is linked. The prospect channel requires the prospect's
  reply-notification opt-in; `reply_channel/1` already treats revoked
  prospects as having no channel. `:none` means there is no recipient at all.

  `send_reply/3` uses this as the primary consent gate for public-intake
  conversations: a non-deliverable public-intake reply is persisted with
  `delivery_status: :withheld` and never handed to delivery.
  `Custyard.Email.Outbound.deliver/1` independently re-checks (defense in
  depth), so no caller can bypass the policy.
  """
  def reply_deliverable?(%Conversation{} = conversation) do
    reply_delivery(conversation) in [:contact, :prospect_opted_in]
  end

  @doc """
  Broadcast a PubSub message on the org-scoped conversations topic
  (`"conversations:org:{id}"`).

  Skips the broadcast entirely when `organization_id` is nil so the malformed
  topic `"conversations:org:"` is never published — subscribers are always
  keyed by a real organization id.
  """
  def broadcast_to_org(nil, _message), do: :ok

  def broadcast_to_org(organization_id, message) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations:org:#{organization_id}",
      message
    )
  end

  @doc """
  Create a message for a conversation.
  Also touches the conversation's updated_at for accurate last-activity tracking.
  """
  def create_message(attrs) do
    Repo.transaction(fn ->
      case %Message{}
           |> Message.changeset(attrs)
           |> Repo.insert() do
        {:ok, message} ->
          # Touch conversation updated_at so it reflects latest activity
          touch_conversation_updated_at(attrs[:conversation_id] || attrs["conversation_id"])
          message

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Run an operator mutation while the conversation's current scope is locked."
  def with_operator_access(id, %OperatorAccount{} = operator, fun) when is_function(fun, 2) do
    Repo.transaction(fn ->
      with %OperatorAccount{} = current_operator <- OperatorAccess.lock_current(operator),
           %Conversation{} = conversation <-
             lock_conversation_for_operator(id, current_operator) do
        case fun.(conversation, current_operator) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        _ -> Repo.rollback(:unauthorized)
      end
    end)
  end

  defp lock_conversation_for_operator(id, operator) do
    query =
      from(c in Conversation, where: c.id == ^id)
      |> scope_conversation_to_operator(operator)

    # This UPDATE obtains the database write lock before checking and acting on
    # the row. A concurrent organization link must finish first or wait until
    # the mutation commits, on both SQLite and PostgreSQL.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(query, set: [updated_at: now]) do
      {1, _} -> Repo.get!(Conversation, id)
      {0, _} -> nil
    end
  end

  defp scope_conversation_to_operator(query, %OperatorAccount{role: "super_admin"}),
    do: query

  defp scope_conversation_to_operator(query, %OperatorAccount{organization_id: org_id})
       when is_integer(org_id),
       do: from(c in query, where: c.organization_id == ^org_id or is_nil(c.organization_id))

  defp scope_conversation_to_operator(query, %OperatorAccount{}),
    do: from(c in query, where: is_nil(c.organization_id))

  @doc """
  Create a message for a conversation, raising on failure.
  Also touches the conversation's updated_at for accurate last-activity tracking.
  """
  def create_message!(attrs) do
    message =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert!()

    # Touch conversation updated_at so it reflects latest activity
    touch_conversation_updated_at(attrs[:conversation_id] || attrs["conversation_id"])
    message
  end

  @doc """
  Soft-delete a message (GitHub-style tombstone).

  Stamps `deleted_at` and the deleting operator; the original body stays in
  the database and rendering surfaces replace it with a tombstone. There is
  deliberately no hard-delete path.

  Idempotent: an already-deleted message is returned unchanged so the
  original deletion attribution is never overwritten.

  Broadcasts `{:message_updated, conversation_id}` on the conversation topic
  (`"conversation:{id}"`) — the same message-level pattern
  `Custyard.Email.Outbound` uses for delivery updates — so open operator,
  prospect, and portal views swap in the tombstone without a remount.
  """
  def soft_delete_message(%Message{deleted_at: %DateTime{}} = message, _operator) do
    {:ok, message}
  end

  def soft_delete_message(%Message{} = message, %OperatorAccount{} = operator) do
    case message |> Message.soft_delete_changeset(operator) |> Repo.update() do
      {:ok, deleted} ->
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversation:#{deleted.conversation_id}",
          {:message_updated, deleted.conversation_id}
        )

        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Send an operator reply to a conversation.

  Creates the outbound message with email metadata (sender_email, in_reply_to,
  message_id, delivery_status), updates conversation state and timestamps,
  recalculates the attention score, and broadcasts PubSub events.

  The entire operation runs inside a transaction so the message and conversation
  update succeed or fail atomically.

  Consent gate (primary layer, public-intake only): the recipient class is
  computed before the insert via `reply_deliverable?/1`, reading committed
  consent state (associations are force-preloaded, so a stale prospect on the
  caller's struct cannot mask a consent flip). When a public-intake
  conversation's reply channel is the prospect email without the prospect's
  reply-notification opt-in, or there is no recipient at all, the reply is
  persisted with `delivery_status: :withheld` and delivery is skipped
  entirely — it reaches the prospect only via the conversation link. Non-intake
  replies always go to delivery, so a missing recipient surfaces as the
  visible `:pending` -> `:failed` path rather than a silent withhold.
  Contact recipients deliver unconditionally.

  ## Options

    * `:operator_email` - email of the operator sending the reply (optional;
      never used for public-intake conversations, which always send from the
      platform address)
    * `:operator` - operator account whose current organization scope must be
      locked and authorized before the reply is inserted
    * `:cc` - CC addresses (list or comma-separated string); each must be a
      valid address, at most 20, or `{:error, {:invalid_cc, ...}}` is returned
      before anything is written. See `default_reply_cc/2` for the list the
      composer starts from

  ## Returns

    * `{:ok, message}` on success
    * `{:error, reason}` on failure (changeset or atom)

  ## Examples

      send_reply(conversation, "Thanks for reaching out!", operator_email: "agent@co.com")

  """
  def send_reply(conversation, body, opts \\ []) do
    with {:ok, cc} <- normalize_cc(Keyword.get(opts, :cc, [])) do
      conversation
      |> reply_transaction(body, Keyword.put(opts, :cc, cc))
      |> handle_reply_transaction()
    end
  end

  @max_cc 20

  # CC addresses the operator typed or accepted: trimmed, lowercased, unique,
  # each a valid address. One bad address rejects the whole reply so nothing
  # goes out to a partial recipient list.
  defp normalize_cc(cc) when is_list(cc) do
    cleaned =
      cc
      |> Enum.flat_map(fn
        value when is_binary(value) -> String.split(value, [",", ";", "\n"])
        _other -> []
      end)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case Enum.reject(cleaned, &EmailAddress.valid?/1) do
      [] when length(cleaned) <= @max_cc -> {:ok, cleaned}
      [] -> {:error, {:invalid_cc, :too_many}}
      invalid -> {:error, {:invalid_cc, invalid}}
    end
  end

  defp normalize_cc(cc) when is_binary(cc), do: normalize_cc([cc])
  defp normalize_cc(_cc), do: {:ok, []}

  @doc """
  The CC list a reply on `conversation` starts with (spec-inbound-channels
  D5, reply-all semantics): the To and CC participants of the latest
  customer-class email message, minus every address that is the
  conversation's own side of the exchange: the customer, the reply From
  identity, the channel's public and ingress addresses, the route sender
  address and the replying operator (`:operator_email`).

  Empty for public-intake and non-email conversations: prospects never get
  a CC, and chat or portal sources carry none.
  """
  def default_reply_cc(conversation, opts \\ [])

  def default_reply_cc(%Conversation{source: source}, _opts)
      when source in [:public_intake, :portal, :slack, :intercom, :zendesk],
      do: []

  def default_reply_cc(%Conversation{} = conversation, opts) do
    case last_customer_email_message(conversation.id) do
      nil ->
        []

      message ->
        excluded = own_side_addresses(conversation, message, opts)

        ((message.cc_addresses || []) ++ (message.to_addresses || []))
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase(String.trim(&1)))
        |> Enum.reject(&(&1 == "" or MapSet.member?(excluded, &1)))
        |> Enum.filter(&EmailAddress.valid?/1)
        |> Enum.uniq()
    end
  end

  defp last_customer_email_message(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.source == :email,
      where: m.is_internal_note == false,
      where: is_nil(m.triage_class) or m.triage_class in [:customer, :operator_forward],
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp own_side_addresses(conversation, message, opts) do
    channel = reply_channel_record(conversation)

    [
      reply_identity(conversation, opts).address,
      Keyword.get(opts, :operator_email),
      SenderMatcher.extract_email(message.sender_email),
      message.reply_to,
      conversation_contact_email(conversation),
      channel && channel.public_address,
      channel && InboundChannels.ingress_address(channel),
      channel && channel.previous_ingress_token &&
        "#{channel.ingress_local}+#{channel.previous_ingress_token}@#{route_domain(channel)}",
      lookup_route_from_address(conversation)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp conversation_contact_email(%Conversation{contact: %Contact{email: email}}), do: email

  defp conversation_contact_email(%Conversation{contact_id: id}) when is_integer(id) do
    case Repo.get(Contact, id) do
      %Contact{email: email} -> email
      nil -> nil
    end
  end

  defp conversation_contact_email(_conversation), do: nil

  defp route_domain(%Custyard.InboundChannel{inbound_route: %Custyard.InboundRoute{} = route}),
    do: route.lettermint_route_domain

  defp route_domain(_channel), do: nil

  defp reply_transaction(conversation, body, opts) do
    Repo.transaction(fn ->
      {conversation, opts} = load_reply_conversation(conversation.id, opts)

      # Recipient and consent decisions use the row and associations read after
      # acquiring the scope lock, never the LiveView's earlier snapshot.
      opts = if conversation.source == :public_intake, do: Keyword.put(opts, :cc, []), else: opts
      deliverable? = reply_deliverable?(conversation)
      attempt_delivery? = deliverable? or conversation.source != :public_intake

      with {:ok, message} <- insert_reply_message(conversation, body, attempt_delivery?, opts),
           {:ok, _conv} <- update_conversation_after_reply(conversation) do
        {message, conversation, attempt_delivery?}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp load_reply_conversation(id, opts) do
    case Keyword.get(opts, :operator) do
      %OperatorAccount{} = operator ->
        current_operator = OperatorAccess.lock_current(operator)

        case current_operator && lock_conversation_for_operator(id, current_operator) do
          nil ->
            Repo.rollback(:unauthorized)

          current ->
            {Repo.preload(current, [:contact, :organization, :prospect]),
             Keyword.put(opts, :operator_email, current_operator.email)}
        end

      nil ->
        {Repo.get!(Conversation, id) |> Repo.preload([:contact, :organization, :prospect]), opts}
    end
  end

  defp handle_reply_transaction({:ok, {message, conversation, attempt_delivery?}}) do
    # The pending message becomes a delivery job only after the transaction
    # commits, and the scanner recovers it if the process stops before waking.
    perform_reply_side_effects(conversation)
    if attempt_delivery?, do: OutboundQueue.wake()
    {:ok, message}
  end

  defp handle_reply_transaction({:error, _reason} = error) do
    error
  end

  # Build and insert the operator reply message with email metadata.
  defp insert_reply_message(conversation, body, attempt_delivery?, opts) do
    last_customer_msg = find_last_customer_message(conversation.id)

    attrs = %{
      source: :operator,
      origin: resolve_outbound_origin(conversation),
      body: body,
      is_internal_note: false,
      conversation_id: conversation.id,
      # Consent gate, primary layer: a public-intake reply with no consenting
      # recipient -> :withheld (see send_reply/3); delivery is skipped by the
      # caller. Non-intake replies always start :pending.
      delivery_status: if(attempt_delivery?, do: :pending, else: :withheld),
      message_id: generate_outbound_message_id(conversation),
      in_reply_to: last_customer_msg && last_customer_msg.message_id,
      sender_email: resolve_sender_email(conversation, opts),
      # Reply-all CC (D5): accepted or edited by the operator in the composer.
      cc_addresses: Keyword.get(opts, :cc, [])
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  # Update conversation state and timestamps after an operator reply.
  # Uses state_changeset/2 to respect the state machine:
  #   - Already :active -> no-op on state (just updates timestamps)
  #   - :new, :waiting, :dormant, :resolved -> transitions to :active
  defp update_conversation_after_reply(conversation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # First, build the state transition changeset (validates or no-ops)
    state_cs = Conversation.state_changeset(conversation, :active)

    # Merge in the operator action timestamp via the regular changeset
    state_cs
    |> Ecto.Changeset.cast(%{last_operator_action_at: now}, [:last_operator_action_at])
    |> Repo.update()
  end

  # Recalculate score and broadcast events after a successful reply.
  defp perform_reply_side_effects(conversation) do
    alias Custyard.Scoring
    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    broadcast_to_org(conversation.organization_id, {:conversation_updated, conversation.id})

    :ok
  end

  # Find the most recent non-operator message to thread In-Reply-To.
  # Queried directly rather than through the caller's (possibly stale,
  # possibly ascending-ordered) preloaded messages; the id ordering breaks
  # ties between rows sharing the same second-precision inserted_at.
  defp find_last_customer_message(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.source != :operator,
      where: m.is_internal_note == false,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  The From identity an operator reply on `conversation` carries
  (spec-inbound-channels D3).

  Returns `%{address, name, source}` where `source` is:

    * `:channel` - the conversation arrived on an inbound channel; `address`
      is the channel's public address (or its ingress address when the
      channel falls back to that identity) and `name` its display name when
      set, else the organization name
    * `:route` - the project or general inbound route's `from_address`
    * `:operator` - `opts[:operator_email]`, when no channel or route
      identity exists
    * `:platform` - nothing above applies; `address` is nil and the
      configured `:email_from_address` fallback is used at delivery. Always
      the case for public-intake conversations, whose `name` is nil because
      the instance branding name applies.

  ## Options

    * `:operator_email` - the replying operator's address, used only for the
      `:operator` source
  """
  @spec reply_identity(struct(), keyword()) :: %{
          address: String.t() | nil,
          name: String.t() | nil,
          source: :channel | :route | :operator | :platform
        }
  def reply_identity(conversation, opts \\ [])

  # Public-intake conversations always send from the platform address: with a
  # nil sender_email, Outbound's :email_from_address fallback applies. Keyed
  # on the conversation's source, not org presence — no inbound route exists
  # for these conversations, and the operator_email fallback would leak the
  # replying operator's personal address to prospects. The rule holds even
  # after the conversation links to an organization (source-keyed rule in the
  # public intake spec).
  def reply_identity(%Conversation{source: :public_intake}, _opts),
    do: %{address: nil, name: nil, source: :platform}

  # Priority: channel From identity > inbound route from_address >
  # operator_email option > platform fallback
  def reply_identity(%Conversation{} = conversation, opts) do
    channel = reply_channel_record(conversation)

    cond do
      address = channel && Custyard.InboundChannels.from_address(channel) ->
        name = Custyard.InboundChannels.from_name(channel) || organization_name(conversation)
        %{address: address, name: name, source: :channel}

      address = lookup_route_from_address(conversation) ->
        %{address: address, name: organization_name(conversation), source: :route}

      address = Keyword.get(opts, :operator_email) ->
        %{address: address, name: organization_name(conversation), source: :operator}

      true ->
        %{address: nil, name: organization_name(conversation), source: :platform}
    end
  end

  # Determine the from address for outbound email: the address of
  # reply_identity/2, nil when the platform fallback applies.
  defp resolve_sender_email(conversation, opts), do: reply_identity(conversation, opts).address

  # The channel the conversation arrived on, from the preloaded association
  # when present, else loaded by id. nil for legacy and non-email
  # conversations.
  defp reply_channel_record(%Conversation{inbound_channel: %Custyard.InboundChannel{} = channel}),
    do: channel

  defp reply_channel_record(%Conversation{inbound_channel_id: id}) when is_integer(id),
    do: Custyard.InboundChannels.get_channel(id)

  defp reply_channel_record(_conversation), do: nil

  defp organization_name(%Conversation{organization: %Custyard.Organization{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp organization_name(%Conversation{organization: %Custyard.Organization{}}), do: nil

  defp organization_name(%Conversation{organization_id: org_id}) when is_integer(org_id) do
    case Repo.get(Custyard.Organization, org_id) do
      %Custyard.Organization{name: name} when is_binary(name) and name != "" -> name
      _organization -> nil
    end
  end

  defp organization_name(_conversation), do: nil

  # Determine origin for outbound replies based on the conversation's source.
  # The origin reflects which integration/adapter the reply is routed through,
  # matching the channel the conversation originally arrived on.
  defp resolve_outbound_origin(conversation) do
    case conversation.source do
      :lettermint -> :lettermint
      :email -> :email
      :zendesk -> :zendesk
      :intercom -> :intercom
      :slack -> :slack
      :portal -> :portal
      # Public-intake replies go out over native email — explicit so the
      # mapping never rides on the catch-all below
      :public_intake -> :email
      # For disambiguation or unknown sources, default to :email
      _ -> :email
    end
  end

  # Prefer the project-specific route so replies flow back through the same
  # webhook/route the conversation arrived on; fall back to the org's
  # general route.
  defp lookup_route_from_address(conversation) do
    project_route_from_address(conversation) || general_route_from_address(conversation)
  end

  defp project_route_from_address(%{project_id: project_id}) when is_integer(project_id) do
    project_id |> Custyard.InboundRoutes.get_project_route() |> route_from_address()
  end

  defp project_route_from_address(_conversation), do: nil

  defp general_route_from_address(%{organization_id: org_id}) when is_integer(org_id) do
    org_id |> Custyard.InboundRoutes.get_general_route() |> route_from_address()
  end

  defp general_route_from_address(_conversation), do: nil

  defp route_from_address(%{from_address: addr}) when is_binary(addr) and addr != "", do: addr
  defp route_from_address(_route), do: nil

  # Generate a unique Message-ID for outbound emails following RFC 5322.
  defp generate_outbound_message_id(conversation) do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    domain = outbound_domain()
    "<#{unique}.c#{conversation.id}@#{domain}>"
  end

  defp outbound_domain do
    Application.get_env(:custyard, :outbound_email_domain, "custyard.local")
  end

  # Update conversation's updated_at without changing any other fields
  defp touch_conversation_updated_at(nil), do: :ok

  defp touch_conversation_updated_at(conversation_id) do
    import Ecto.Query

    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])

    :ok
  end

  # --- Task functions ---

  alias Custyard.Task

  @doc """
  Get a task by ID.
  WARNING: No org scoping - use get_task_for_organization/2 for user-facing requests.
  """
  def get_task!(id) do
    Repo.get!(Task, id)
  end

  @doc """
  Get a task by ID, scoped to organization.
  Checks task's organization_id, conversation's organization_id, or project's organization_id.
  Returns `{:ok, task}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def get_task_for_organization(id, org_id) do
    case Repo.get(Task, id) |> Repo.preload([:conversation, :project]) do
      nil ->
        {:error, :not_found}

      task ->
        # Task can be scoped via direct org_id, or via conversation/project
        task_org = task.organization_id
        conv_org = task.conversation && task.conversation.organization_id
        proj_org = task.project && task.project.organization_id

        if org_id in [task_org, conv_org, proj_org] and not is_nil(org_id) do
          {:ok, task}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Create a task.
  """
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update task state.
  """
  def update_task_state(task, new_state) do
    task
    |> Task.state_changeset(new_state)
    |> Repo.update()
  end

  @doc """
  Update a task with the given attributes.
  """
  def update_task(task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a task.
  WARNING: No org scoping - use delete_task_for_organization/2 for user-facing requests.
  """
  def delete_task(task) do
    Repo.delete(task)
  end

  @doc """
  Delete a task, scoped to organization.
  Returns `{:ok, task}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def delete_task_for_organization(id, org_id) do
    case get_task_for_organization(id, org_id) do
      {:ok, task} -> Repo.delete(task)
      error -> error
    end
  end

  @doc """
  List portal-visible tasks for a conversation.
  """
  def list_portal_visible_tasks(conversation_id) do
    from(t in Task,
      where: t.conversation_id == ^conversation_id,
      where: t.portal_visible == true,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Delete orphaned tasks that have no organization, conversation, or project.
  These can occur due to SQLite FK constraints using nilify_all on delete.
  Returns the number of tasks deleted.
  """
  def delete_orphaned_tasks do
    {count, _} =
      from(t in Task,
        where: is_nil(t.organization_id),
        where: is_nil(t.conversation_id),
        where: is_nil(t.project_id)
      )
      |> Repo.delete_all()

    count
  end

  # Resolved :public_intake conversations are retained longer than the
  # standard bound to honor the months-later conversation path (spec: NFR Retention).
  @public_intake_retention_days 365

  @doc """
  Delete resolved conversations older than the retention bound.
  Also deletes associated messages and the prospect row (via FK cascade) and
  cleans up orphaned contacts. Returns the number of conversations deleted.

  Retention splits by source: `days_old` (90 via `run_cleanup/1`) applies to
  every source except `:public_intake`, which is retained for 365 days after
  resolution so a prospect returning months later still finds the thread.
  Once purged, the prospect row cascades away with the conversation, so the
  access token no longer resolves and the conversation URL renders the uniform
  unavailable page.

  Options:
    - :dry_run - if true, returns count without deleting (default: false)
    - :public_intake_days - retention for resolved `:public_intake`
      conversations (default: 365)
  """
  def cleanup_resolved_conversations(days_old, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    intake_days = Keyword.get(opts, :public_intake_days, @public_intake_retention_days)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -days_old * 24 * 60 * 60, :second)
    intake_cutoff = DateTime.add(now, -intake_days * 24 * 60 * 60, :second)

    query =
      from(c in Conversation,
        where: c.state == :resolved,
        where:
          ((is_nil(c.source) or c.source != ^:public_intake) and c.updated_at < ^cutoff) or
            (c.source == ^:public_intake and c.updated_at < ^intake_cutoff)
      )

    if dry_run do
      Repo.aggregate(query, :count)
    else
      delete_conversations_with_audit_trail(query)
    end
  end

  # audit_events.conversation_id is a plain FK (ON DELETE NO ACTION), so a
  # single DELETE over every expired conversation fails as a whole as soon as
  # one of them has an audit event (every conversion, slug release and
  # audited webhook delivery writes one), and the sweep then retries the same
  # failing statement forever. Detach the audit rows first, in the same
  # transaction, so the trail survives the purge and the purge survives the
  # trail.
  #
  # Both statements evaluate the retention query itself rather than a list
  # of ids read beforehand: the detach is the transaction's first write, so
  # SQLite holds the write lock from then until commit, and no reply, note
  # or reopen can land between the two statements and make them disagree.
  defp delete_conversations_with_audit_trail(query) do
    {:ok, count} =
      Repo.transaction(fn ->
        expired_ids = from(c in query, select: c.id)

        from(a in Custyard.AuditEvent, where: a.conversation_id in subquery(expired_ids))
        |> Repo.update_all(set: [conversation_id: nil])

        {deleted, _} = Repo.delete_all(query)
        deleted
      end)

    count
  end

  @doc """
  Delete contacts that have no conversations.
  These can accumulate when conversations are deleted.
  Returns the number of contacts deleted.

  Options:
    - :dry_run - if true, returns count without deleting (default: false)
  """
  def cleanup_orphaned_contacts(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    # Find contacts with no conversations. Expressed as NOT EXISTS rather
    # than an anti-join because SQLite rejects JOINs in DELETE statements,
    # and this query is used for both the count and the delete.
    query =
      from(ct in Custyard.Contact,
        as: :contact,
        where:
          not exists(
            from(c in Conversation,
              where: c.contact_id == parent_as(:contact).id,
              select: 1
            )
          )
      )

    if dry_run do
      Repo.aggregate(query, :count)
    else
      {count, _} = Repo.delete_all(query)
      count
    end
  end

  @doc """
  Run all cleanup operations.
  Returns a map with counts for each cleanup type.

  Options:
    - :resolved_days - delete resolved conversations older than this
      (default: 90); resolved `:public_intake` conversations use the longer
      `:public_intake_days` bound instead
    - :public_intake_days - retention for resolved `:public_intake`
      conversations (default: 365)
    - :dry_run - if true, returns counts without deleting (default: false)
  """
  def run_cleanup(opts \\ []) do
    resolved_days = Keyword.get(opts, :resolved_days, 90)
    intake_days = Keyword.get(opts, :public_intake_days, @public_intake_retention_days)
    dry_run = Keyword.get(opts, :dry_run, false)

    resolved_count =
      cleanup_resolved_conversations(resolved_days,
        dry_run: dry_run,
        public_intake_days: intake_days
      )

    contacts_count = cleanup_orphaned_contacts(dry_run: dry_run)
    tasks_count = if dry_run, do: count_orphaned_tasks(), else: delete_orphaned_tasks()

    %{
      resolved_conversations: resolved_count,
      orphaned_contacts: contacts_count,
      orphaned_tasks: tasks_count
    }
  end

  defp count_orphaned_tasks do
    from(t in Task,
      where: is_nil(t.organization_id),
      where: is_nil(t.conversation_id),
      where: is_nil(t.project_id)
    )
    |> Repo.aggregate(:count)
  end
end

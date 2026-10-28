defmodule Custyard.Threads do
  @moduledoc """
  Context for thread queries and operations.
  """

  alias Custyard.{
    Thread,
    EmailAddress,
    Message,
    StaffAccess,
    StaffAccount,
    Repo
  }

  alias Custyard.Email.{OutboundQueue, ReplyRecipients}
  import Ecto.Query

  def list(%Custyard.Scope{tenant_id: tenant_id} = scope, opts \\ []) do
    if Custyard.Scope.current_staff(scope),
      do: list_for_attention_queue(Keyword.put(opts, :tenant_id, tenant_id)),
      else: []
  end

  def get(%Custyard.Scope{tenant_id: tenant_id} = scope, id) do
    if Custyard.Scope.current_staff(scope),
      do: Repo.get_by(Thread, id: id, tenant_id: tenant_id)
  end

  def get!(%Custyard.Scope{} = scope, id),
    do: get(scope, id) || raise(Ecto.NoResultsError, queryable: Thread)

  def get_with_messages(%Custyard.Scope{} = scope, id) do
    case get(scope, id) do
      nil -> nil
      thread -> load_with_messages(thread.id)
    end
  end

  def neglected(%Custyard.Scope{tenant_id: tenant_id} = scope, opts \\ []) do
    if Custyard.Scope.current_staff(scope),
      do: list_neglected(Keyword.put(opts, :tenant_id, tenant_id)),
      else: []
  end

  def with_access(%Custyard.Scope{} = scope, id, fun) do
    case Custyard.Scope.current_staff(scope) do
      nil -> {:error, :unauthorized}
      staff -> with_staff_access(id, staff, fun)
    end
  end

  def create(%Custyard.Scope{tenant_id: tenant_id} = scope, attrs) do
    if Custyard.Scope.current_staff(scope) do
      attrs =
        Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
        |> Map.put("tenant_id", tenant_id)

      create_thread(attrs)
    else
      {:error, :unauthorized}
    end
  end

  defp list_for_attention_queue(opts) do
    filter = Keyword.get(opts, :filter, "all")
    organization_id = Keyword.get(opts, :organization_id)
    now = DateTime.utc_now()

    message_count_subquery =
      from(m in Message,
        group_by: m.thread_id,
        select: %{thread_id: m.thread_id, count: count(m.id)}
      )

    due_task_subquery =
      from(t in Custyard.Task,
        where: t.state != :done and not is_nil(t.due_at) and t.due_at <= ^now,
        group_by: t.thread_id,
        select: %{thread_id: t.thread_id, count: count(t.id), due_at: min(t.due_at)}
      )

    query =
      from(c in Thread,
        # Left join: disambiguation/public-intake threads have nil organization_id
        left_join: o in assoc(c, :organization),
        left_join: ct in assoc(c, :contact),
        # Prospect preload feeds reply_channel/1 without N+1 queries
        left_join: p in assoc(c, :prospect),
        left_join: ch in assoc(c, :inbound_channel),
        left_join: mc in subquery(message_count_subquery),
        on: mc.thread_id == c.id,
        left_join: dt in subquery(due_task_subquery),
        as: :due_tasks,
        on: dt.thread_id == c.id,
        # Resolving/snoozing a thread must not hide an unfinished task
        # that has reached its own deadline.
        where: c.state != :resolved or not is_nil(dt.thread_id),
        order_by: [desc: coalesce(dt.count, 0), asc: dt.due_at, desc: c.cached_score],
        preload: [organization: o, contact: ct, prospect: p, inbound_channel: ch],
        select: %{
          thread: c,
          message_count: coalesce(mc.count, 0),
          due_task_count: coalesce(dt.count, 0)
        }
      )

    query
    |> apply_organization_filter(organization_id)
    |> apply_tenant_filter(Keyword.get(opts, :tenant_id))
    |> apply_snooze_filter(filter, now)
    |> apply_state_filter(filter)
    |> apply_label_filter(Keyword.get(opts, :label_id))
    |> Repo.all()
  end

  # Filter for snoozed threads - only show snoozed when explicitly filtered
  defp apply_snooze_filter(query, "snoozed", now) do
    from(c in query, where: c.snoozed_until >= ^now)
  end

  defp apply_snooze_filter(query, _filter, now) do
    from([c, due_tasks: dt] in query,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now or not is_nil(dt.thread_id)
    )
  end

  defp apply_label_filter(query, nil), do: query

  defp apply_label_filter(query, label_id) when is_integer(label_id) do
    from(c in query,
      join: cl in Custyard.ThreadLabel,
      on: cl.thread_id == c.id,
      join: l in Custyard.Label,
      on: l.id == cl.label_id,
      where: l.id == ^label_id and l.tenant_id == c.tenant_id
    )
  end

  defp apply_tenant_filter(query, nil), do: query

  defp apply_tenant_filter(query, id) when is_integer(id),
    do: from(c in query, where: c.tenant_id == ^id)

  # Org-scoped staffs also see threads without an organization
  # (unlinked prospects); see list_for_attention_queue/1.
  defp apply_organization_filter(query, nil), do: query

  defp apply_organization_filter(query, org_id) when is_integer(org_id) do
    from(c in query, where: c.organization_id == ^org_id or is_nil(c.organization_id))
  end

  defp apply_state_filter(query, "all"), do: query
  defp apply_state_filter(query, "new"), do: from(c in query, where: c.state == :new)
  defp apply_state_filter(query, "active"), do: from(c in query, where: c.state == :active)
  defp apply_state_filter(query, "waiting"), do: from(c in query, where: c.state == :waiting)
  defp apply_state_filter(query, "dormant"), do: from(c in query, where: c.state == :dormant)

  defp apply_state_filter(query, "due_tasks"),
    do: from([due_tasks: dt] in query, where: not is_nil(dt.thread_id))

  defp apply_state_filter(query, _), do: query

  defp list_neglected(opts) do
    organization_id = Keyword.get(opts, :organization_id)
    now = DateTime.utc_now()

    from(c in Thread,
      # Left join: disambiguation threads have nil organization_id
      left_join: o in assoc(c, :organization),
      left_join: ct in assoc(c, :contact),
      where: c.state != :resolved,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
      # Order by org name (nil sorts first), then by score
      order_by: [asc_nulls_first: o.name, desc: c.cached_score],
      preload: [organization: o, contact: ct]
    )
    |> apply_organization_filter(organization_id)
    |> apply_tenant_filter(Keyword.get(opts, :tenant_id))
    |> Repo.all()
  end

  @doc """
  List threads for an organization's portal view.

  Options:
    - :include_resolved - include resolved threads (default: false)
    - :contact_id - filter to only this contact's threads (default: nil = all)
  """
  def list_for_organization(org_id, opts \\ []) do
    include_resolved = Keyword.get(opts, :include_resolved, false)
    contact_id = Keyword.get(opts, :contact_id)

    query =
      from(c in Thread,
        where: c.organization_id == ^org_id,
        order_by: [desc: c.inserted_at],
        preload: [:contact]
      )

    query =
      if contact_id do
        from(c in query, where: c.contact_id == ^contact_id)
      else
        query
      end

    query =
      if include_resolved do
        query
      else
        from(c in query, where: c.state != :resolved)
      end

    Repo.all(query)
  end

  @doc """
  Get thread for organization with ownership check.
  Returns `{:ok, thread}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def get_thread_for_organization(id, org_id) do
    case Repo.get(Thread, id) |> Repo.preload([:contact, :organization]) do
      nil ->
        {:error, :not_found}

      thread ->
        if thread.organization_id == org_id do
          {:ok, thread}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp load_with_messages(id) do
    Repo.get!(Thread, id)
    |> Repo.preload([
      :organization,
      :contact,
      # Feeds reply_channel/1 and reply_deliverable?/1 without extra queries
      :prospect,
      :tasks,
      # Channel badge and the reply From identity (spec-inbound-channels D3)
      inbound_channel: :inbound_route,
      # Attachments and per-recipient delivery outcomes for the thread
      messages: {from(m in Message, order_by: m.inserted_at), [:attachments, :recipient_statuses]}
    ])
  end

  @doc """
  Clear or set the triage suspect flag on a thread (staff action).
  """
  def set_suspect(%Thread{} = thread, suspect?) when is_boolean(suspect?) do
    with {:ok, updated} <-
           thread |> Thread.suspect_changeset(suspect?) |> Repo.update() do
      broadcast_to_org(updated.organization_id, {:thread_updated, updated.id})

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "threads",
        {:thread_updated, updated.id}
      )

      {:ok, updated}
    end
  end

  @doc """
  Get thread with preloaded messages, scoped to organization.
  Returns `{:ok, thread}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  Use this for user-facing requests to prevent IDOR.
  """
  def get_with_messages_for_organization(id, org_id) do
    case Repo.get(Thread, id) do
      nil ->
        {:error, :not_found}

      thread ->
        if thread.organization_id == org_id do
          preloaded =
            Repo.preload(thread, [
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
  Get public messages for a thread (excludes internal notes).
  """
  def list_public_messages(thread_id) do
    from(m in Message,
      where: m.thread_id == ^thread_id,
      where: m.is_internal_note == false,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Count messages for a thread.
  """
  def count_messages(thread_id) do
    from(m in Message, where: m.thread_id == ^thread_id, select: count(m.id))
    |> Repo.one()
  end

  defp create_thread(attrs) do
    %Thread{}
    |> Thread.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update thread state.
  """
  def update_state(thread, new_state) do
    thread
    |> Thread.state_changeset(new_state)
    |> Repo.update()
  end

  @doc """
  Snooze a thread until the given datetime.
  """
  def snooze(thread, until) do
    thread
    |> Thread.snooze_changeset(until)
    |> Repo.update()
  end

  @doc """
  Un-snooze a thread, making it appear in the attention queue again.
  """
  def unsnooze(thread) do
    thread
    |> Thread.snooze_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Update thread with allowed changes (goes through changeset for validation).
  Note: cached_score and last_neglect_notification are not allowed - they are computed fields.
  """
  def update_thread(thread, attrs) do
    thread
    |> Thread.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically transition a thread from one state to another.

  Uses a conditional UPDATE to prevent race conditions when multiple staffs
  access the same thread simultaneously. Only updates if the thread
  is still in the expected `from_state`.

  Returns:
    - `{:ok, updated_thread}` if the transition succeeded
    - `{:ok, :already_transitioned}` if thread was already in a different state
    - `{:error, changeset}` if the update failed for other reasons

  ## Examples

      # Transition from :new to :active when staff views
      transition_state(thread, :new, :active, last_staff_action_at: now)

  """
  def transition_state(thread, from_state, to_state, additional_attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Keyword.merge([state: to_state, updated_at: now], additional_attrs)

    # Build the update query with a WHERE condition on current state
    query =
      from(c in Thread,
        where: c.id == ^thread.id and c.state == ^from_state
      )

    case Repo.update_all(query, set: attrs) do
      {1, _} ->
        # Successfully updated - reload to get fresh data
        {:ok, Repo.get!(Thread, thread.id) |> Repo.preload([:organization, :contact])}

      {0, _} ->
        # No rows updated - state was already different, check current state
        current =
          Repo.get!(Thread, thread.id) |> Repo.preload([:organization, :contact])

        if current.state == to_state do
          # Already in target state - another staff transitioned it first
          {:ok, :already_transitioned}
        else
          # In some other state - return the current thread
          {:ok, :already_transitioned}
        end
    end
  end

  @doc """
  Reload a thread from the database.
  """
  def reload!(thread) do
    Repo.reload!(thread)
  end

  @doc """
  Derive the reply channel for a thread.

  Returns `{:contact, email}` when the linked contact has an email (always
  preferred), `{:prospect, email}` when a prospect captured an email and
  thread access has not been revoked, and `:none` otherwise.

  The "no reply channel" state is derived, never stored — capturing an email
  clears it with zero clearing code. Contact and prospect are preloaded only
  when not already loaded, so preloading callers (the attention queue) pay no
  extra queries.
  """
  def reply_channel(%Thread{} = thread) do
    thread = preload_reply_channel_assocs(thread)

    cond do
      email = contact_email(thread.contact) -> {:contact, email}
      email = prospect_email(thread.prospect) -> {:prospect, email}
      true -> :none
    end
  end

  defp preload_reply_channel_assocs(thread) do
    if Ecto.assoc_loaded?(thread.contact) and Ecto.assoc_loaded?(thread.prospect) do
      thread
    else
      Repo.preload(thread, [:contact, :prospect])
    end
  end

  defp contact_email(%Custyard.Contact{email: email}) when is_binary(email) and email != "",
    do: email

  defp contact_email(_contact), do: nil

  # Prospect email counts only while thread access is not revoked
  defp prospect_email(%Custyard.Prospect{email: email, revoked_at: nil})
       when is_binary(email) and email != "",
       do: email

  defp prospect_email(_prospect), do: nil

  @doc """
  Classify how a staff reply on this thread would be delivered.

  Returns one of:

    * `:contact` — the linked contact has an email; delivers unconditionally
      (established-customer path)
    * `:prospect_opted_in` — a prospect email was captured with the
      reply-notification opt-in; delivers
    * `:prospect_no_consent` — a prospect email was captured but the prospect
      has not opted into email replies; the consent-advisory state
    * `:none` — no recipient at all (no email captured, or thread access
      revoked)

  The staff UI keys the consent advisory on `:prospect_no_consent`
  specifically — the `:none` states are conveyed by the reply-channel badge,
  not the opt-in wording.

  Callers must pass a `thread` with fresh `:contact`/`:prospect`
  associations. If they are already `Ecto.assoc_loaded?`, this function reuses
  them as-is rather than re-reading from the database — a stale preload (e.g.
  a prospect's `notify_on_reply` flipped after it was loaded) silently
  produces a stale consent decision.
  """
  def reply_delivery(%Thread{} = thread) do
    thread = preload_reply_channel_assocs(thread)

    case reply_channel(thread) do
      {:contact, _email} ->
        :contact

      {:prospect, _email} ->
        if thread.prospect.notify_on_reply,
          do: :prospect_opted_in,
          else: :prospect_no_consent

      :none ->
        :none
    end
  end

  @doc """
  Whether a staff reply on this thread will be emailed.

  Contact recipients deliver unconditionally — the established-customer path,
  including when a captured prospect email matched an existing contact and the
  thread is linked. The prospect channel requires the prospect's
  reply-notification opt-in; `reply_channel/1` already treats revoked
  prospects as having no channel. `:none` means there is no recipient at all.

  `send_reply/3` uses this as the primary consent gate for public-intake
  threads: a non-deliverable public-intake reply is persisted with
  `delivery_status: :withheld` and never handed to delivery.
  `Custyard.Email.Outbound.deliver/1` independently re-checks (defense in
  depth), so no caller can bypass the policy.
  """
  def reply_deliverable?(%Thread{} = thread) do
    reply_delivery(thread) in [:contact, :prospect_opted_in]
  end

  @doc """
  Broadcast a PubSub message on the org-scoped threads topic
  (`"threads:org:{id}"`).

  Skips the broadcast entirely when `organization_id` is nil so the malformed
  topic `"threads:org:"` is never published — subscribers are always
  keyed by a real organization id.
  """
  def broadcast_to_org(nil, _message), do: :ok

  def broadcast_to_org(organization_id, message) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "threads:org:#{organization_id}",
      message
    )
  end

  @doc """
  Create a message for a thread.
  Also touches the thread's updated_at for accurate last-activity tracking.
  """
  def create_message(attrs) do
    Repo.transaction(fn ->
      case %Message{}
           |> Message.changeset(attrs)
           |> Repo.insert() do
        {:ok, message} ->
          # Touch thread updated_at so it reflects latest activity
          touch_thread_updated_at(attrs[:thread_id] || attrs["thread_id"])
          message

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp with_staff_access(id, %StaffAccount{} = staff, fun) when is_function(fun, 2) do
    Repo.transaction(fn ->
      with %StaffAccount{} = current_staff <- StaffAccess.lock_current(staff),
           true <-
             StaffAccount.session_claim_matches?(current_staff, staff.session_claim),
           true <- Custyard.Tenants.active?(current_staff.tenant_id),
           %Thread{} = thread <-
             lock_thread_for_staff(id, current_staff) do
        case fun.(thread, current_staff) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        _ -> Repo.rollback(:unauthorized)
      end
    end)
  end

  defp lock_thread_for_staff(id, staff) do
    query =
      from(c in Thread, where: c.id == ^id)
      |> scope_thread_to_staff(staff)

    # This UPDATE obtains the database write lock before checking and acting on
    # the row. A concurrent organization link must finish first or wait until
    # the mutation commits, on both SQLite and PostgreSQL.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(query, set: [updated_at: now]) do
      {1, _} -> Repo.get!(Thread, id)
      {0, _} -> nil
    end
  end

  defp scope_thread_to_staff(query, %StaffAccount{tenant_id: tenant_id})
       when is_integer(tenant_id),
       do: where(query, [c], c.tenant_id == ^tenant_id)

  defp scope_thread_to_staff(query, %StaffAccount{}), do: where(query, [c], false)

  @doc """
  Create a message for a thread, raising on failure.
  Also touches the thread's updated_at for accurate last-activity tracking.
  """
  def create_message!(attrs) do
    message =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert!()

    # Touch thread updated_at so it reflects latest activity
    touch_thread_updated_at(attrs[:thread_id] || attrs["thread_id"])
    message
  end

  @doc """
  Soft-delete a message (GitHub-style tombstone).

  Stamps `deleted_at` and the deleting staff; the original body stays in
  the database and rendering surfaces replace it with a tombstone. There is
  deliberately no hard-delete path.

  Idempotent: an already-deleted message is returned unchanged so the
  original deletion attribution is never overwritten.

  Broadcasts `{:message_updated, thread_id}` on the thread topic
  (`"thread:{id}"`) — the same message-level pattern
  `Custyard.Email.Outbound` uses for delivery updates — so open staff,
  prospect, and portal views swap in the tombstone without a remount.
  """
  def soft_delete_message(%Message{deleted_at: %DateTime{}} = message, _staff) do
    {:ok, message}
  end

  def soft_delete_message(%Message{} = message, %StaffAccount{} = staff) do
    case message |> Message.soft_delete_changeset(staff) |> Repo.update() do
      {:ok, deleted} ->
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "thread:#{deleted.thread_id}",
          {:message_updated, deleted.thread_id}
        )

        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Send a staff reply to a thread.

  Creates the outbound message with email metadata (sender_email, in_reply_to,
  message_id, delivery_status), updates thread state and timestamps,
  recalculates the attention score, and broadcasts PubSub events.

  The entire operation runs inside a transaction so the message and thread
  update succeed or fail atomically.

  Consent gate (primary layer, public-intake only): the recipient class is
  computed before the insert via `reply_deliverable?/1`, reading committed
  consent state (associations are force-preloaded, so a stale prospect on the
  caller's struct cannot mask a consent flip). When a public-intake
  thread's reply channel is the prospect email without the prospect's
  reply-notification opt-in, or there is no recipient at all, the reply is
  persisted with `delivery_status: :withheld` and delivery is skipped
  entirely — it reaches the prospect only via the thread link. Non-intake
  replies always go to delivery, so a missing recipient surfaces as the
  visible `:pending` -> `:failed` path rather than a silent withhold.
  Contact recipients deliver unconditionally.

  ## Options

    * `:staff_email` - email of the staff sending the reply (optional;
      never used for public-intake threads, which always send from the
      platform address)
    * `:staff` - staff account whose current organization scope must be
      locked and authorized before the reply is inserted
    * `:cc` - CC addresses (list or comma-separated string); each must be a
      valid address, at most 20, or `{:error, {:invalid_cc, ...}}` is returned
      before anything is written. See `default_reply_cc/2` for the list the
      composer starts from

  ## Returns

    * `{:ok, message}` on success
    * `{:error, reason}` on failure (changeset or atom)

  ## Examples

      send_reply(thread, "Thanks for reaching out!", staff_email: "agent@co.com")

  """
  def send_reply(thread, body, opts \\ []) do
    with {:ok, cc} <- normalize_cc(Keyword.get(opts, :cc, [])) do
      thread
      |> reply_transaction(body, Keyword.put(opts, :cc, cc))
      |> handle_reply_transaction()
    end
  end

  @max_cc 20

  # CC addresses the staff typed or accepted: trimmed, lowercased, unique,
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
  The CC list a reply on `thread` starts with (spec-inbound-channels
  D5, reply-all semantics): the To and CC participants of the latest
  customer-class email message, minus every address that is the
  thread's own side of the exchange: the customer, the reply From
  identity, the channel's public and ingress addresses, the route sender
  address and the replying staff (`:staff_email`).

  Empty for public-intake and non-email threads: prospects never get
  a CC, and chat or portal sources carry none.
  """
  def default_reply_cc(thread, opts \\ []),
    do: ReplyRecipients.default_cc(thread, opts)

  defp reply_transaction(thread, body, opts) do
    Repo.transaction(fn ->
      {thread, opts} = load_reply_thread(thread.id, opts)

      # Recipient and consent decisions use the row and associations read after
      # acquiring the scope lock, never the LiveView's earlier snapshot.
      opts = if thread.source == :public_intake, do: Keyword.put(opts, :cc, []), else: opts
      deliverable? = reply_deliverable?(thread)
      attempt_delivery? = deliverable? or thread.source != :public_intake

      with {:ok, message} <- insert_reply_message(thread, body, attempt_delivery?, opts),
           {:ok, _conv} <- update_thread_after_reply(thread) do
        {message, thread, attempt_delivery?}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp load_reply_thread(id, opts) do
    case Keyword.get(opts, :staff) do
      %StaffAccount{} = staff ->
        current_staff = StaffAccess.lock_current(staff)

        case current_staff && lock_thread_for_staff(id, current_staff) do
          nil ->
            Repo.rollback(:unauthorized)

          current ->
            {Repo.preload(current, [:contact, :organization, :prospect]),
             Keyword.put(opts, :staff_email, current_staff.email)}
        end

      nil ->
        {Repo.get!(Thread, id) |> Repo.preload([:contact, :organization, :prospect]), opts}
    end
  end

  defp handle_reply_transaction({:ok, {message, thread, attempt_delivery?}}) do
    # The pending message becomes a delivery job only after the transaction
    # commits, and the scanner recovers it if the process stops before waking.
    perform_reply_side_effects(thread)
    if attempt_delivery?, do: OutboundQueue.wake()
    {:ok, message}
  end

  defp handle_reply_transaction({:error, _reason} = error) do
    error
  end

  # Build and insert the staff reply message with email metadata.
  defp insert_reply_message(thread, body, attempt_delivery?, opts) do
    last_customer_msg = find_last_customer_message(thread.id)
    channel = reply_sending_channel(thread)

    recipient =
      case ReplyRecipients.recipient(thread) do
        {:ok, address} -> address
        {:error, _reason} -> nil
      end

    if Keyword.has_key?(opts, :expected_recipient) and
         Keyword.get(opts, :expected_recipient) != recipient do
      Repo.rollback(:recipient_changed)
    end

    attrs = %{
      source: :staff,
      origin: resolve_outbound_origin(thread),
      body: body,
      is_internal_note: false,
      thread_id: thread.id,
      # Consent gate, primary layer: a public-intake reply with no consenting
      # recipient -> :withheld (see send_reply/3); delivery is skipped by the
      # caller. Non-intake replies always start :pending.
      delivery_status: if(attempt_delivery?, do: :pending, else: :withheld),
      message_id: generate_outbound_message_id(thread),
      in_reply_to: last_customer_msg && last_customer_msg.message_id,
      sender_email: resolve_sender_email(thread, opts),
      inbound_channel_id: channel && channel.id,
      to_addresses: if(recipient, do: [recipient], else: []),
      # Reply-all CC (D5): accepted or edited by the staff in the composer.
      cc_addresses: Keyword.get(opts, :cc, [])
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Ecto.Changeset.change(delivery_recipients_locked: true)
    |> Repo.insert()
  end

  # Update thread state and timestamps after a staff reply.
  # Uses state_changeset/2 to respect the state machine:
  #   - Already :active -> no-op on state (just updates timestamps)
  #   - :new, :waiting, :dormant, :resolved -> transitions to :active
  defp update_thread_after_reply(thread) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # First, build the state transition changeset (validates or no-ops)
    state_cs = Thread.state_changeset(thread, :active)

    # Merge in the staff action timestamp via the regular changeset
    state_cs
    |> Ecto.Changeset.cast(%{last_staff_action_at: now}, [:last_staff_action_at])
    |> Repo.update()
  end

  # Recalculate score and broadcast events after a successful reply.
  defp perform_reply_side_effects(thread) do
    alias Custyard.Scoring
    Scoring.calculate_and_cache(thread.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread.id}",
      {:message_added, thread.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "threads",
      {:thread_updated, thread.id}
    )

    broadcast_to_org(thread.organization_id, {:thread_updated, thread.id})

    :ok
  end

  # Find the most recent non-staff message to thread In-Reply-To.
  # Queried directly rather than through the caller's (possibly stale,
  # possibly ascending-ordered) preloaded messages; the id ordering breaks
  # ties between rows sharing the same second-precision inserted_at.
  defp find_last_customer_message(thread_id) do
    from(m in Message,
      where: m.thread_id == ^thread_id,
      where: m.source != :staff,
      where: m.is_internal_note == false and is_nil(m.deleted_at),
      where: is_nil(m.triage_class) or m.triage_class in [:customer, :staff_forward],
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  The From identity a staff reply on `thread` carries
  (spec-inbound-channels D3).

  Returns `%{address, name, source}` where `source` is:

    * `:channel` - the thread arrived on an inbound channel; `address`
      is the public mailbox local part at the channel's sending domain
      (or its ingress address when the
      channel falls back to that identity) and `name` its display name when
      set, else the organization name
    * `:route` - the project or general inbound route's `from_address`
    * `:staff` - `opts[:staff_email]`, when no channel or route
      identity exists
    * `:platform` - nothing above applies; `address` is nil and the
      configured `:email_from_address` fallback is used at delivery. Always
      the case for public-intake threads, whose `name` is nil because
      the instance branding name applies.

  ## Options

    * `:staff_email` - the replying staff's address, used only for the
      `:staff` source
  """
  @spec reply_identity(struct(), keyword()) :: %{
          address: String.t() | nil,
          name: String.t() | nil,
          source: :channel | :route | :staff | :platform
        }
  def reply_identity(thread, opts \\ [])

  def reply_identity(%Thread{} = thread, _opts) do
    case reply_sending_channel(thread) do
      %Custyard.InboundChannel{} = channel ->
        %{
          address: Custyard.InboundChannels.from_address(channel),
          name: reply_channel_name(channel),
          source: :channel
        }

      nil ->
        %{address: nil, name: tenant_name(thread.tenant_id), source: :platform}
    end
  end

  # Determine the from address for outbound email: the address of
  # reply_identity/2, nil when the platform fallback applies.
  defp resolve_sender_email(thread, opts), do: reply_identity(thread, opts).address

  @doc "The tenant-owned sending channel, snapshotted on an outbound reply at enqueue."
  def reply_sending_channel(%Thread{} = thread) do
    reply_channel_record(thread) ||
      case Custyard.EmailSetup.default_reply_channel(thread.tenant_id) do
        {:ok, channel} -> channel
        {:error, _reason} -> nil
      end
  end

  defp tenant_name(tenant_id) do
    case Repo.get(Custyard.Tenant, tenant_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # The channel the thread arrived on, from the preloaded association
  # when present, else loaded by id. nil for legacy and non-email
  # threads.
  defp reply_channel_record(%Thread{inbound_channel: %Custyard.InboundChannel{} = channel}),
    do: channel

  defp reply_channel_record(%Thread{inbound_channel_id: id}) when is_integer(id),
    do: Custyard.InboundChannels.get_channel(id)

  defp reply_channel_record(_thread), do: nil

  defp reply_channel_name(channel) do
    Custyard.InboundChannels.from_name(channel) || tenant_name(channel.tenant_id)
  end

  # Determine origin for outbound replies based on the thread's source.
  # The origin reflects which integration/adapter the reply is routed through,
  # matching the channel the thread originally arrived on.
  defp resolve_outbound_origin(thread) do
    case thread.source do
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

  # Generate a unique Message-ID for outbound emails following RFC 5322.
  defp generate_outbound_message_id(thread) do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    domain = outbound_domain()
    "<#{unique}.c#{thread.id}@#{domain}>"
  end

  defp outbound_domain do
    Application.get_env(:custyard, :outbound_email_domain, "custyard.local")
  end

  # Update thread's updated_at without changing any other fields
  defp touch_thread_updated_at(nil), do: :ok

  defp touch_thread_updated_at(thread_id) do
    import Ecto.Query

    from(c in Thread, where: c.id == ^thread_id)
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
  Checks task's organization_id, thread's organization_id, or project's organization_id.
  Returns `{:ok, task}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def get_task_for_organization(id, org_id) do
    case Repo.get(Task, id) |> Repo.preload([:thread, :project]) do
      nil ->
        {:error, :not_found}

      task ->
        # Task can be scoped via direct org_id, or via thread/project
        task_org = task.organization_id
        conv_org = task.thread && task.thread.organization_id
        proj_org = task.project && task.project.organization_id

        scopes = Enum.reject([task_org, conv_org, proj_org], &is_nil/1)

        if scopes != [] and Enum.all?(scopes, &(&1 == org_id)) and not is_nil(org_id) do
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
    |> task_changed()
  end

  @doc """
  Update task state.
  """
  def update_task_state(task, new_state) do
    task
    |> Task.state_changeset(new_state)
    |> Repo.update()
    |> task_changed()
  end

  @doc """
  Update a task with the given attributes.
  """
  def update_task(task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
    |> task_changed()
  end

  @doc """
  Delete a task.
  WARNING: No org scoping - use delete_task_for_organization/2 for user-facing requests.
  """
  def delete_task(task) do
    task |> Repo.delete() |> task_changed()
  end

  defp task_changed({:ok, task} = result) do
    broadcast_task_change(task)
    result
  end

  defp task_changed(error), do: error

  @doc false
  def broadcast_task_change(task) do
    if task.thread_id do
      event = {:thread_updated, task.thread_id}
      Phoenix.PubSub.broadcast(Custyard.PubSub, "threads", event)
      Phoenix.PubSub.broadcast(Custyard.PubSub, "thread:#{task.thread_id}", event)
      thread = Repo.get(Thread, task.thread_id)
      if thread, do: broadcast_to_org(thread.organization_id, event)
    end

    :ok
  end

  @doc """
  Delete a task, scoped to organization.
  Returns `{:ok, task}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def delete_task_for_organization(id, org_id) do
    case get_task_for_organization(id, org_id) do
      {:ok, task} -> delete_task(task)
      error -> error
    end
  end

  @doc """
  List portal-visible tasks for a thread.
  """
  def list_portal_visible_tasks(thread_id) do
    from(t in Task,
      where: t.thread_id == ^thread_id,
      where: t.portal_visible == true,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Delete orphaned tasks that have no organization, thread, or project.
  These can occur due to SQLite FK constraints using nilify_all on delete.
  Returns the number of tasks deleted.
  """
  def delete_orphaned_tasks do
    {count, _} =
      from(t in Task,
        where: is_nil(t.organization_id),
        where: is_nil(t.thread_id),
        where: is_nil(t.project_id)
      )
      |> Repo.delete_all()

    count
  end

  # Resolved :public_intake threads are retained longer than the
  # standard bound to honor the months-later thread path (spec: NFR Retention).
  @public_intake_retention_days 365

  @doc """
  Delete resolved threads older than the retention bound.
  Also deletes associated messages and the prospect row (via FK cascade) and
  cleans up orphaned contacts. Returns the number of threads deleted.

  Retention splits by source: `days_old` (90 via `run_cleanup/1`) applies to
  every source except `:public_intake`, which is retained for 365 days after
  resolution so a prospect returning months later still finds the thread.
  Once purged, the prospect row cascades away with the thread, so the
  access token no longer resolves and the thread URL renders the uniform
  unavailable page.

  Options:
    - :dry_run - if true, returns count without deleting (default: false)
    - :public_intake_days - retention for resolved `:public_intake`
      threads (default: 365)
  """
  def cleanup_resolved_threads(days_old, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    intake_days = Keyword.get(opts, :public_intake_days, @public_intake_retention_days)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -days_old * 24 * 60 * 60, :second)
    intake_cutoff = DateTime.add(now, -intake_days * 24 * 60 * 60, :second)

    query =
      from(c in Thread,
        where: c.state == :resolved,
        where:
          ((is_nil(c.source) or c.source != ^:public_intake) and c.updated_at < ^cutoff) or
            (c.source == ^:public_intake and c.updated_at < ^intake_cutoff)
      )

    if dry_run do
      Repo.aggregate(query, :count)
    else
      delete_threads_with_audit_trail(query)
    end
  end

  # audit_events.thread_id is a plain FK (ON DELETE NO ACTION), so a
  # single DELETE over every expired thread fails as a whole as soon as
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
  defp delete_threads_with_audit_trail(query) do
    {:ok, count} =
      Repo.transaction(fn ->
        expired_ids = from(c in query, select: c.id)

        from(a in Custyard.AuditEvent, where: a.thread_id in subquery(expired_ids))
        |> Repo.update_all(set: [thread_id: nil])

        from(p in Custyard.Project, where: p.thread_id in subquery(expired_ids))
        |> Repo.update_all(set: [thread_id: nil])

        from(t in Custyard.Task, where: t.thread_id in subquery(expired_ids))
        |> Repo.update_all(set: [thread_id: nil])

        from(e in Custyard.EmailConnection,
          where: e.latest_received_thread_id in subquery(expired_ids)
        )
        |> Repo.update_all(set: [latest_received_thread_id: nil])

        from(s in Custyard.Slug, where: s.thread_id in subquery(expired_ids))
        |> Repo.delete_all()

        {deleted, _} = Repo.delete_all(query)
        deleted
      end)

    count
  end

  @doc """
  Delete contacts that have no threads.
  These can accumulate when threads are deleted.
  Returns the number of contacts deleted.

  Options:
    - :dry_run - if true, returns count without deleting (default: false)
  """
  def cleanup_orphaned_contacts(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    # Find contacts with no threads. Expressed as NOT EXISTS rather
    # than an anti-join because SQLite rejects JOINs in DELETE statements,
    # and this query is used for both the count and the delete.
    query =
      from(ct in Custyard.Contact,
        as: :contact,
        where:
          not exists(
            from(c in Thread,
              where: c.contact_id == parent_as(:contact).id,
              select: 1
            )
          )
      )

    if dry_run do
      Repo.aggregate(query, :count)
    else
      Repo.transaction(fn ->
        contact_ids = from(ct in query, select: ct.id)

        from(c in Custyard.PortalCredential, where: c.contact_id in subquery(contact_ids))
        |> Repo.update_all(set: [contact_id: nil])

        {count, _} = Repo.delete_all(query)
        count
      end)
      |> case do
        {:ok, count} -> count
        {:error, reason} -> raise "Contact cleanup failed: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Run all cleanup operations.
  Returns a map with counts for each cleanup type.

  Options:
    - :resolved_days - delete resolved threads older than this
      (default: 90); resolved `:public_intake` threads use the longer
      `:public_intake_days` bound instead
    - :public_intake_days - retention for resolved `:public_intake`
      threads (default: 365)
    - :dry_run - if true, returns counts without deleting (default: false)
  """
  def run_cleanup(opts \\ []) do
    resolved_days = Keyword.get(opts, :resolved_days, 90)
    intake_days = Keyword.get(opts, :public_intake_days, @public_intake_retention_days)
    dry_run = Keyword.get(opts, :dry_run, false)

    resolved_count =
      cleanup_resolved_threads(resolved_days,
        dry_run: dry_run,
        public_intake_days: intake_days
      )

    contacts_count = cleanup_orphaned_contacts(dry_run: dry_run)
    tasks_count = if dry_run, do: count_orphaned_tasks(), else: delete_orphaned_tasks()

    %{
      resolved_threads: resolved_count,
      orphaned_contacts: contacts_count,
      orphaned_tasks: tasks_count
    }
  end

  defp count_orphaned_tasks do
    from(t in Task,
      where: is_nil(t.organization_id),
      where: is_nil(t.thread_id),
      where: is_nil(t.project_id)
    )
    |> Repo.aggregate(:count)
  end
end

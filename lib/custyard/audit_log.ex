defmodule Custyard.AuditLog do
  @moduledoc """
  The read side of `audit_events`: the timelines shown to a tenant's
  administrators and to instance administrators.

  A tenant admin reads every event of their own tenant (`for_tenant/2`). An
  instance admin reads installation events and what instance admins did to a
  tenant: creating or suspending it, adding or removing a hostname,
  provisioning a staff account (`for_instance/2`).
  They never read an event of a tenant's own work: instance administration
  carries no customer access.

  Entries are built for display here, not in the views. A stored payload goes
  through `Custyard.AuditEvent.Payload.minimize/2` again before anything is
  read from it, so a row written before payloads were minimized cannot put an
  address or message text on the page. RFC Message-IDs are never shown.
  """

  import Ecto.Query

  alias Custyard.{
    AuditEvent,
    Authorization,
    Contact,
    InboundChannel,
    InstanceAdmin,
    Organization,
    Repo,
    Scope,
    StaffAccount,
    Tenant,
    Thread
  }

  alias Custyard.AuditEvent.Payload
  alias Custyard.Auth.Account

  defmodule Entry do
    @moduledoc """
    One audit event, ready to show.

    `actor` and `summary` are plain text. `thread` (`%{id, subject}`) and
    `customer` (`%{id, public_id, name}`) are set for a tenant admin when the
    event has them; the customer page is opened by `public_id`. `tenant`
    (`%{id, name}`) is set for an instance admin; nil there means the event
    belongs to the installation.
    """
    @enforce_keys [:id, :at, :event_type, :topic, :actor, :summary]
    defstruct [:id, :at, :event_type, :topic, :actor, :summary, :thread, :customer, :tenant]
  end

  @page_size 50

  # Machine records of mail moving in and out. They outnumber everything
  # else, so the default view leaves them out.
  @mail [
    :webhook_received,
    :webhook_processed,
    :webhook_error,
    :delivery_status_updated,
    :inbound_triaged
  ]

  # Every event type belongs to exactly one topic.
  @topics [
    conversations:
      {"Conversations",
       [
         :thread_state_changed,
         :sender_ignored,
         :reply_queued,
         :internal_note_created,
         :reply_retried,
         :prospect_converted
       ]},
    customers:
      {"Customers",
       [
         :slug_released,
         :acknowledgment_replayed,
         :acknowledgment_binding_created,
         :data_subject_erasure
       ]},
    channels:
      {"Channels",
       [
         :channel_created,
         :channel_updated,
         :channel_deleted,
         :channel_state_changed,
         :channel_token_rotated,
         :channel_token_revealed,
         :channel_verification_captured,
         :channel_sending_domain_checked,
         :channel_quiet
       ]},
    workspace:
      {"Workspace",
       [
         :staff_created,
         :staff_removed,
         :tenant_created,
         :tenant_status_changed,
         :tenant_host_added,
         :tenant_host_removed,
         :outbound_pause_changed
       ]},
    mail: {"Mail processing", @mail},
    installation:
      {"Installation",
       [:instance_admin_created, :instance_admin_removed, :installation_configured]}
  ]

  # The tenant page's filters. Installation events have no tenant, so that
  # topic is not offered there.
  @tenant_topics [:conversations, :customers, :channels, :workspace, :mail]
  @default_category "actions"

  @doc "Entries on one page."
  def page_size, do: @page_size

  @doc """
  The filters of the tenant timeline, in display order, as `%{id, label}`.

  `"actions"` is everything except mail processing and is the default.
  `"everything"` is every event.
  """
  def categories do
    [%{id: @default_category, label: "Actions"}] ++
      for(topic <- @tenant_topics, do: %{id: Atom.to_string(topic), label: topic_label(topic)}) ++
      [%{id: "everything", label: "Everything"}]
  end

  @doc "The filter shown when none, or an unknown one, is asked for."
  def default_category, do: @default_category

  @doc "`id` when it names a filter of the tenant timeline, otherwise the default."
  def category(id) do
    if Enum.any?(categories(), &(&1.id == id)), do: id, else: @default_category
  end

  @doc "The topic an event type belongs to, as listed in `topics/0`."
  def topic(event_type) do
    Enum.find_value(@topics, fn {topic, {_label, types}} -> if event_type in types, do: topic end)
  end

  @doc "Every topic with its event types: `%{topic => [event_type]}`."
  def topics, do: Map.new(@topics, fn {topic, {_label, types}} -> {topic, types} end)

  @doc "The display name of a topic."
  def topic_label(topic) do
    {label, _types} = Keyword.fetch!(@topics, topic)
    label
  end

  @doc """
  An id as it arrives in a URL parameter: the positive integer a string of
  digits names. Anything else is nil, including a number longer than the
  database holds. The pages read `thread` and `before` through this, so a
  hand-edited address cannot fail a query.
  """
  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> positive(id)
      _ -> nil
    end
  end

  def parse_id(value), do: positive(value)

  @doc """
  The audit timeline of the scope's tenant, newest first.

  Options:

    * `:category` - a filter id from `categories/0`; default `"actions"`
    * `:thread_id` - only events of this thread
    * `:before` - only events older than the entry with this id, which is how
      the next page is asked for

  Returns `{:ok, %{entries: [%Entry{}], older: id | nil, thread: map | nil}}`.
  `older` is the `:before` value of the next page, nil on the last one.
  `thread` is `%{id, subject}` of the thread filtered on, nil when there is no
  such thread in the tenant.

  Only a current admin of the tenant may read it; anyone else gets
  `{:error, :unauthorized}`.
  """
  def for_tenant(%Scope{} = scope, opts \\ []) do
    with %StaffAccount{} = staff <- Scope.current_staff(scope),
         true <- Authorization.can_view_audit_log?(staff) do
      tenant_id = staff.tenant_id
      thread_id = positive(opts[:thread_id])

      rows =
        from(e in AuditEvent,
          where: e.tenant_id == ^tenant_id,
          left_join: t in Thread,
          on: t.id == e.thread_id and t.tenant_id == e.tenant_id,
          # Reply and note events name the thread only; its customer is theirs.
          left_join: o in Organization,
          on:
            o.id == coalesce(e.organization_id, t.organization_id) and
              o.tenant_id == e.tenant_id,
          select: %{
            event: e,
            thread_subject: t.subject,
            customer_id: o.id,
            customer_public_id: o.public_id,
            customer: o.name
          }
        )
        |> in_category(category(opts[:category]))
        |> of_thread(thread_id)
        |> page_of(opts[:before])
        |> Repo.all()

      {rows, older} = paginate(rows, & &1.event.id)
      rows = Enum.map(rows, &%{&1 | event: minimized(&1.event)})
      context = tenant_context(tenant_id, Enum.map(rows, & &1.event))

      {:ok,
       %{
         entries: Enum.map(rows, &tenant_entry(&1, context)),
         older: older,
         thread: thread_id && filtered_thread(tenant_id, thread_id)
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  The audit timeline of the installation, newest first: events that belong to
  no tenant, and what instance admins did to a tenant.

  Takes `:before` like `for_tenant/2` and returns
  `{:ok, %{entries: [%Entry{}], older: id | nil}}`. An entry never has a
  thread or a customer, and names tenant staff only as "Tenant staff".

  Only a current instance admin may read it; anyone else gets
  `{:error, :unauthorized}`.
  """
  def for_instance(admin, opts \\ [])

  def for_instance(%InstanceAdmin{id: id, session_claim: claim}, opts) when is_integer(id) do
    with %InstanceAdmin{} = current <- Repo.get(InstanceAdmin, id),
         true <- Account.session_claim_matches?(current, claim) do
      rows =
        from(e in AuditEvent, where: is_nil(e.tenant_id) or e.source == "instance_admin")
        |> page_of(opts[:before])
        |> Repo.all()

      {events, older} = paginate(rows, & &1.id)
      events = Enum.map(events, &minimized/1)
      context = instance_context(events)

      {:ok, %{entries: Enum.map(events, &entry(&1, context)), older: older}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def for_instance(_admin, _opts), do: {:error, :unauthorized}

  # -- Query -----------------------------------------------------------------

  defp in_category(query, "everything"), do: query
  defp in_category(query, "actions"), do: where(query, [e], e.event_type not in ^@mail)

  defp in_category(query, id) do
    {_label, types} = Keyword.fetch!(@topics, String.to_existing_atom(id))
    where(query, [e], e.event_type in ^types)
  end

  defp of_thread(query, nil), do: query
  defp of_thread(query, thread_id), do: where(query, [e], e.thread_id == ^thread_id)

  # One row more than a page, which says whether an older page exists.
  defp page_of(query, before) do
    query =
      case positive(before) do
        nil -> query
        id -> where(query, [e], e.id < ^id)
      end

    query |> order_by([e], desc: e.id) |> limit(^(@page_size + 1))
  end

  defp paginate(rows, id_of) do
    case Enum.split(rows, @page_size) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, page |> List.last() |> id_of.()}
    end
  end

  # Ids are 64-bit in the database. A longer number names no row and cannot
  # be bound to a query, so it is no id at all.
  @max_id 9_223_372_036_854_775_807

  defp positive(value) when is_integer(value) and value > 0 and value <= @max_id, do: value
  defp positive(_value), do: nil

  defp filtered_thread(tenant_id, thread_id) do
    Repo.one(
      from(t in Thread,
        where: t.id == ^thread_id and t.tenant_id == ^tenant_id,
        select: %{id: t.id, subject: t.subject}
      )
    )
  end

  # A row written before payloads were minimized may hold addresses or
  # message text. Nothing below reads a payload that has not been through
  # the allowlist of its event type.
  defp minimized(%AuditEvent{} = event),
    do: %{event | payload: Payload.minimize(event.payload, event.event_type)}

  # -- Names behind the ids --------------------------------------------------

  defp tenant_context(tenant_id, events) do
    %{
      audience: :tenant,
      staff: names(StaffAccount, tenant_id, ids(events, ~w(staff_id actor_staff_id)), :email),
      channels: names(InboundChannel, tenant_id, ids(events, ~w(channel_id)), :public_address),
      contacts: names(Contact, tenant_id, ids(events, ~w(contact_id)), :email),
      admins: %{},
      tenants: %{}
    }
  end

  defp instance_context(events) do
    tenant_ids = events |> Enum.map(& &1.tenant_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      audience: :instance,
      staff: %{},
      channels: %{},
      contacts: %{},
      admins: names(InstanceAdmin, ids(events, ~w(instance_admin_id)), :email),
      tenants: names(Tenant, tenant_ids, :name)
    }
  end

  defp ids(events, keys) do
    for(%{payload: payload} <- events, key <- keys, id = payload[key], is_integer(id), do: id)
    |> Enum.uniq()
  end

  defp names(_schema, _tenant_id, [], _field), do: %{}

  defp names(schema, tenant_id, ids, field) do
    from(r in schema,
      where: r.tenant_id == ^tenant_id and r.id in ^ids,
      select: {r.id, field(r, ^field)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp names(_schema, [], _field), do: %{}

  defp names(schema, ids, field) do
    from(r in schema, where: r.id in ^ids, select: {r.id, field(r, ^field)})
    |> Repo.all()
    |> Map.new()
  end

  # -- Entries ---------------------------------------------------------------

  defp tenant_entry(%{event: event} = row, context) do
    %{
      entry(event, context)
      | thread: event.thread_id && %{id: event.thread_id, subject: row.thread_subject},
        customer:
          row.customer_id &&
            %{id: row.customer_id, public_id: row.customer_public_id, name: row.customer},
        tenant: nil
    }
  end

  defp entry(%AuditEvent{} = event, context) do
    %Entry{
      id: event.id,
      at: event.inserted_at,
      event_type: event.event_type,
      topic: topic(event.event_type),
      actor: actor(event, context),
      summary: summary(event.event_type, event.payload || %{}, context),
      tenant:
        event.tenant_id &&
          %{id: event.tenant_id, name: Map.get(context.tenants, event.tenant_id)}
    }
  end

  # -- Who -------------------------------------------------------------------

  # An instance admin account is the subject of these two, not who acted.
  defp actor(%AuditEvent{event_type: type}, _context)
       when type in [:instance_admin_created, :instance_admin_removed],
       do: "Installation"

  # staff_id is the account created or removed; the actor has its own keys.
  defp actor(%AuditEvent{event_type: type, payload: payload} = event, context)
       when type in [:staff_created, :staff_removed] do
    cond do
      id = payload["actor_staff_id"] -> staff(id, context)
      id = payload["instance_admin_id"] -> admin(id, context)
      payload["via"] in ~w(cli mix console) -> "Command line"
      true -> source_actor(event.source)
    end
  end

  defp actor(%AuditEvent{payload: payload} = event, context) do
    cond do
      id = payload["staff_id"] -> staff(id, context)
      id = payload["instance_admin_id"] -> admin(id, context)
      payload["actor"] in ~w(cli mix console) -> "Command line"
      payload["actor"] == "system" -> "System"
      true -> source_actor(event.source)
    end
  end

  defp staff(_id, %{audience: :instance}), do: "Tenant staff"
  defp staff(id, context), do: Map.get(context.staff, id, "Removed staff account")

  # A tenant is told an instance admin acted, not which one.
  defp admin(_id, %{audience: :tenant}), do: "Instance admin"
  defp admin(id, context), do: Map.get(context.admins, id, "Removed instance admin")

  defp source_actor("staff"), do: "Staff"
  defp source_actor("instance_admin"), do: "Instance admin"
  defp source_actor(source) when source in ~w(cli mix console dsar), do: "Command line"
  defp source_actor(_source), do: "System"

  # -- What ------------------------------------------------------------------

  defp summary(:thread_state_changed, payload, _context) do
    case {payload["from"], payload["to"]} do
      {from, to} when is_binary(from) and is_binary(to) ->
        "Changed the state from #{words(from)} to #{words(to)}"

      {_from, to} when is_binary(to) ->
        "Changed the state to #{words(to)}"

      _ ->
        "Changed the state"
    end
  end

  defp summary(:sender_ignored, payload, context) do
    sender =
      case Map.get(context.contacts, payload["contact_id"]) do
        nil -> "the sender"
        email -> "the sender #{email}"
      end

    if payload["ignored"] == false, do: "Stopped ignoring #{sender}", else: "Ignored #{sender}"
  end

  defp summary(:reply_queued, _payload, _context), do: "Queued a reply for delivery"
  defp summary(:internal_note_created, _payload, _context), do: "Added an internal note"
  defp summary(:reply_retried, _payload, _context), do: "Retried sending a reply"
  defp summary(:prospect_converted, _payload, _context), do: "Converted a prospect to a customer"

  defp summary(:slug_released, payload, _context) do
    case payload["slug"] do
      nil -> "Released a slug"
      slug -> "Released the slug #{slug}"
    end
  end

  defp summary(:acknowledgment_replayed, payload, _context),
    do: "Replayed acknowledgments" <> detail(payload["outcome"] || payload["category"])

  defp summary(:acknowledgment_binding_created, _payload, _context),
    do: "Linked an acknowledgment source to a customer"

  defp summary(:data_subject_erasure, payload, _context) do
    counts =
      for {key, label} <- [
            {"messages_erased", "messages erased"},
            {"attachments_removed", "attachments removed"},
            {"threads_retitled", "conversations retitled"},
            {"contacts_removed", "contacts removed"}
          ],
          count = payload[key],
          is_integer(count) and count > 0,
          do: "#{count} #{label}"

    case counts do
      [] -> "Erased a data subject's records"
      counts -> "Erased a data subject's records: " <> Enum.join(counts, ", ")
    end
  end

  defp summary(:channel_created, payload, context), do: "Created #{channel(payload, context)}"
  defp summary(:channel_deleted, payload, context), do: "Deleted #{channel(payload, context)}"

  defp summary(:channel_updated, payload, context) do
    case payload["changed"] do
      [_ | _] = fields ->
        "Updated #{channel(payload, context)}: " <> Enum.map_join(fields, ", ", &words/1)

      _ ->
        "Updated #{channel(payload, context)}"
    end
  end

  defp summary(:channel_state_changed, payload, context) do
    case {payload["from"], payload["to"]} do
      {from, to} when is_binary(from) and is_binary(to) ->
        "Changed #{channel(payload, context)} from #{words(from)} to #{words(to)}"

      _ ->
        "Changed the state of #{channel(payload, context)}"
    end
  end

  defp summary(:channel_token_rotated, payload, context),
    do: "Rotated the ingress address of #{channel(payload, context)}"

  defp summary(:channel_token_revealed, payload, context),
    do: "Revealed the ingress address of #{channel(payload, context)}"

  defp summary(:channel_verification_captured, payload, context),
    do: "Captured a forwarding verification for #{channel(payload, context)}"

  defp summary(:channel_sending_domain_checked, payload, _context) do
    case payload["domain"] do
      nil -> "Checked a sending domain" <> detail(payload["status"])
      domain -> "Checked the sending domain #{domain}" <> detail(payload["status"])
    end
  end

  defp summary(:channel_quiet, payload, context),
    do: "No mail arrived at #{channel(payload, context)} for longer than expected"

  defp summary(:staff_created, payload, context),
    do: "Created #{staff_account(payload, context)}"

  defp summary(:staff_removed, payload, context),
    do: "Removed #{staff_account(payload, context)}"

  defp summary(:tenant_created, payload, _context) do
    case payload["hostname"] do
      nil -> "Created the workspace"
      hostname -> "Created the workspace at #{hostname}"
    end
  end

  defp summary(:tenant_status_changed, %{"status" => "suspended"}, _context),
    do: "Suspended the workspace"

  defp summary(:tenant_status_changed, %{"status" => "active"}, _context),
    do: "Resumed the workspace"

  defp summary(:tenant_status_changed, _payload, _context), do: "Changed the workspace status"

  defp summary(:tenant_host_added, payload, _context) do
    case payload["hostname"] do
      nil -> "Added a hostname"
      hostname -> "Added the hostname #{hostname}"
    end
  end

  defp summary(:tenant_host_removed, payload, _context) do
    case payload["hostname"] do
      nil -> "Removed a hostname"
      hostname -> "Removed the hostname #{hostname}"
    end
  end

  defp summary(:outbound_pause_changed, %{"paused" => false}, _context),
    do: "Resumed outbound replies"

  defp summary(:outbound_pause_changed, _payload, _context), do: "Paused outbound replies"

  defp summary(:webhook_received, payload, _context),
    do: "Received an inbound message" <> detail(payload["source"])

  defp summary(:webhook_processed, payload, _context),
    do: "Processed an inbound message" <> detail(payload["outcome"])

  defp summary(:webhook_error, payload, _context),
    do:
      "Failed to process an inbound message" <>
        detail(payload["error_code"] || payload["outcome"] || payload["reason"])

  defp summary(:delivery_status_updated, payload, _context) do
    change =
      case {payload["from"], payload["to"]} do
        {from, to} when is_binary(from) and is_binary(to) ->
          "Delivery of a reply went from #{words(from)} to #{words(to)}"

        {_from, to} when is_binary(to) ->
          "Delivery of a reply became #{words(to)}"

        _ ->
          "Delivery status of a reply changed"
      end

    change <> detail(payload["reason_code"])
  end

  defp summary(:inbound_triaged, payload, _context) do
    case payload["class"] do
      nil -> "Classified an inbound message"
      class -> "Classified an inbound message as #{words(class)}"
    end
  end

  defp summary(:instance_admin_created, payload, context),
    do: "Created #{admin_account(payload, context)}"

  defp summary(:instance_admin_removed, payload, context),
    do: "Removed #{admin_account(payload, context)}"

  defp summary(:installation_configured, _payload, _context), do: "Completed installation setup"

  defp channel(payload, context) do
    case Map.get(context.channels, payload["channel_id"]) do
      nil -> "a support channel"
      address -> "the support channel #{address}"
    end
  end

  defp staff_account(payload, context) do
    role = if payload["role"] in ~w(admin agent), do: payload["role"] <> " ", else: ""

    case Map.get(context.staff, payload["staff_id"]) do
      nil -> "#{article(role)} #{role}staff account"
      email -> "the #{role}staff account #{email}"
    end
  end

  defp admin_account(payload, context) do
    case Map.get(context.admins, payload["instance_admin_id"]) do
      nil -> "an instance admin account"
      email -> "the instance admin account #{email}"
    end
  end

  defp article("a" <> _rest), do: "an"
  defp article(_role), do: "a"

  defp detail(value) when is_binary(value), do: " (#{words(value)})"
  defp detail(_value), do: ""

  # "pending_verification" and "message.hard_bounced" as words.
  defp words(value), do: value |> to_string() |> String.replace(["_", "."], " ")
end

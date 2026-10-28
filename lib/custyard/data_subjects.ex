defmodule Custyard.DataSubjects do
  @moduledoc """
  Data subject requests for people who appear on email messages
  (spec-inbound-channels, Privacy and compliance).

  A contact's own threads are findable through the contact record. A
  CC'd or To'd bystander has no record of their own (D5: participants are
  not contacts), so export and erasure must also search the recipient
  lists and `Reply-To` of every message in the organization. This module
  is that search, plus the two operations built on it:

    * `export/2` lists every message the address appears on, with the role
      it played (`:sender`, `:to`, `:cc`, `:reply_to`). The body is included
      only for messages the person sent; on a message they merely received,
      the body is somebody else's correspondence.
    * `erase_participation/2` removes the address from recipient lists and
      `Reply-To` on messages the person did not send. Messages they sent are
      left alone; the counts tell the staff how many those are.
    * `erase_subject/2` is the contact-level erasure: the participation
      erasure, plus the person's own messages, their attachments, their
      contact record, the subjects of their threads and their
      rejection-log entries. Staff replies keep their text, without the
      person's address.

  `bin/dsar` (`Custyard.Release.Dsar`; `mix custyard.dsar` in development)
  wraps them for staffs until a UI exists.
  Addresses are matched case-insensitively; the audit event written on
  erasure records counts only, never the address.
  """

  import Ecto.Query

  alias Custyard.Email.SenderMatcher

  alias Custyard.{
    AuditEvent,
    Contact,
    Thread,
    EmailAddress,
    InboundChannelRejection,
    Message,
    MessageAttachment,
    MessageRecipientStatus,
    Repo
  }

  # The recipient arrays are JSON text on SQLite and native arrays on
  # Postgres, so the containment test is adapter-specific. The adapter is
  # compile-time configuration (see Custyard.Repo).
  @postgres? Application.compile_env(:custyard, :repo_adapter, Custyard.Repo.Adapter) ==
               Ecto.Adapters.Postgres

  @type role :: :sender | :to | :cc | :reply_to

  @doc """
  Every message in `organization_id` the address appears on, newest first,
  each with the roles the address plays on it.
  """
  @spec participations(
          Custyard.Scope.t() | Custyard.DataSubjects.LocalAuthority.t(),
          String.t(),
          integer()
        ) :: [
          %{message: Message.t(), thread: Thread.t(), roles: [role()]}
        ]
  def participations(scope, email, organization_id) when is_binary(email) do
    authorize_customer!(scope, organization_id, false)
    email = normalize(email)

    email
    |> participation_query(organization_id)
    |> Repo.all()
    |> Enum.map(fn {message, thread} ->
      %{message: message, thread: thread, roles: roles(message, email)}
    end)
    |> Enum.reject(&(&1.roles == []))
  end

  @doc "Export for a data subject request. See the moduledoc for what is included."
  def export(scope, email, organization_id) when is_binary(email) do
    authorize_customer!(scope, organization_id, false)
    email = normalize(email)

    messages =
      for %{message: message, thread: thread, roles: roles} <-
            participations(scope, email, organization_id) do
        %{
          message_id: message.id,
          thread_id: thread.id,
          subject: thread.subject,
          roles: roles,
          at: message.inserted_at,
          sender: if(:sender in roles, do: message.sender_email),
          body: if(:sender in roles, do: message.body)
        }
      end

    %{
      email: email,
      organization_id: organization_id,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      messages: messages
    }
  end

  @doc """
  Remove the address from `to_addresses`, `cc_addresses` and `reply_to` on
  every message in the organization the person did not send. Returns
  `{:ok, %{erased: n, sent_by_subject: m}}`; `sent_by_subject` counts the
  messages left for the contact-level erasure.
  """
  def erase_participation(scope, email, organization_id)
      when is_binary(email) do
    email = normalize(email)

    in_write_transaction(scope, organization_id, fn ->
      {sent, received} = locked_participations(email, organization_id)
      count = Enum.count(received, &scrub!(&1, email))
      erase_recipient_statuses!(email, organization_id)
      payload = %{"erased" => count, "sent_by_subject" => length(sent)}
      audit!(organization_id, payload)
      %{erased: count, sent_by_subject: length(sent)}
    end)
  end

  @doc """
  Contact-level erasure of the address in `organization_id`:

    * on messages the person did not send, the address leaves the recipient
      lists and `Reply-To`, as in `erase_participation/2`;
    * messages the person sent are tombstoned (`deleted_at`, so every view
      shows "This message was deleted") and emptied: body, HTML, sender,
      recipients, `Reply-To` and authentication. The rows stay so threading
      by Message-ID keeps working;
    * those messages' attachment rows are deleted; the attachment sweep
      removes the files once nothing references them;
    * the person's contact record is deleted, and the threads it
      owned lose the contact and their subject;
    * rejection-log entries from the address are deleted.

  Staff replies keep their text. Returns `{:ok, counts}` and writes a
  `data_subject_erasure` audit event with the same counts and no address.
  """
  def erase_subject(scope, email, organization_id) when is_binary(email) do
    email = normalize(email)

    in_write_transaction(scope, organization_id, fn ->
      {sent, received} = locked_participations(email, organization_id)
      erased = Enum.count(received, &scrub!(&1, email))
      scrub_audit_identity!(scope.tenant_id, email, organization_id, sent)
      erase_recipient_statuses!(email, organization_id)
      sent_ids = Enum.map(sent, & &1.id)
      Enum.each(sent, &erase_sent!/1)
      Repo.delete_all(from(r in MessageRecipientStatus, where: r.message_id in ^sent_ids))

      {attachments, _} =
        Repo.delete_all(from(a in MessageAttachment, where: a.message_id in ^sent_ids))

      {threads, contacts} = erase_contact!(email, organization_id)
      erase_prospect_identity!(email, organization_id)
      erase_slug_identity!(email, organization_id)
      anonymize_personal_customer!(email, organization_id)
      rejections = erase_rejections!(scope.tenant_id, email, organization_id)

      counts = %{
        erased: erased,
        messages_erased: length(sent),
        attachments_removed: attachments,
        threads_retitled: threads,
        contacts_removed: contacts,
        rejections_removed: rejections
      }

      audit!(organization_id, Map.new(counts, fn {key, value} -> {to_string(key), value} end))
      counts
    end)
  end

  @erased_subject "(erased)"

  # Acquire SQLite's write reservation before reading, or lock matching
  # PostgreSQL rows. Concurrent erasures must never overwrite one another's
  # changes from a stale message snapshot.
  defp in_write_transaction(scope, organization_id, fun) do
    Repo.transaction(
      fn ->
        lock_authority!(scope)
        authorize_customer!(scope, organization_id, true)
        fun.()
      end,
      if(@postgres?, do: [], else: [mode: :immediate])
    )
  end

  defp lock_authority!(%Custyard.Scope{} = scope) do
    Custyard.StaffAccess.lock_current(%Custyard.StaffAccount{id: scope.staff_id})
    lock_tenant(scope.tenant_id)
  end

  defp lock_authority!(%Custyard.DataSubjects.LocalAuthority{tenant_id: id}), do: lock_tenant(id)

  defp lock_tenant(tenant_id) do
    Repo.update_all(
      from(t in Custyard.Tenant,
        where: t.id == ^tenant_id,
        update: [set: [updated_at: t.updated_at]]
      ),
      []
    )
  end

  defp authorize_customer!(%{tenant_id: tenant_id} = scope, organization_id, erase?) do
    authorize_scope!(scope, erase?)

    unless Repo.exists?(
             from o in Custyard.Organization,
               where: o.id == ^organization_id and o.tenant_id == ^tenant_id
           ),
           do: raise(Ecto.NoResultsError, queryable: Custyard.Organization)

    :ok
  end

  defp authorize_scope!(%Custyard.Scope{} = scope, erase?) do
    case Custyard.Scope.current_staff(scope) do
      %Custyard.StaffAccount{role: "admin"} -> :ok
      %Custyard.StaffAccount{} when not erase? -> :ok
      _ -> deny_scope!(erase?)
    end
  end

  defp authorize_scope!(%Custyard.DataSubjects.LocalAuthority{}, _erase?), do: :ok
  defp authorize_scope!(_, erase?), do: deny_scope!(erase?)
  defp deny_scope!(true), do: Repo.rollback(:unauthorized)
  defp deny_scope!(false), do: raise(Ecto.NoResultsError, queryable: Custyard.Organization)

  defp scrub_audit_identity!(tenant_id, email, organization_id, sent) do
    customer_threads =
      from c in Thread, where: c.organization_id == ^organization_id, select: c.id

    contact_ids =
      from c in Contact,
        where: c.organization_id == ^organization_id,
        where: fragment("lower(trim(?))", c.email) == ^email,
        select: c.id

    contact_threads =
      Repo.all(from c in Thread, where: c.contact_id in subquery(contact_ids), select: c.id)

    erased_threads = MapSet.new(contact_threads ++ Enum.map(sent, & &1.thread_id))

    from(a in AuditEvent,
      where: a.tenant_id == ^tenant_id,
      where: a.organization_id == ^organization_id or a.thread_id in subquery(customer_threads)
    )
    |> Repo.all()
    |> Enum.each(&scrub_audit_event!(&1, email, erased_threads))
  end

  defp scrub_audit_event!(event, email, erased_threads) do
    payload = event.payload || %{}

    sender_matches =
      Enum.any?(["sender_email", "from"], fn field ->
        SenderMatcher.extract_email(payload[field]) == email
      end)

    if sender_matches or MapSet.member?(erased_threads, event.thread_id) do
      event
      |> Ecto.Changeset.change(payload: Map.drop(payload, ["sender_email", "from", "subject"]))
      |> Repo.update!()
    end
  end

  defp erase_prospect_identity!(email, organization_id) do
    threads = from c in Thread, where: c.organization_id == ^organization_id, select: c.id

    from(p in Custyard.Prospect,
      where: p.thread_id in subquery(threads),
      where: fragment("lower(trim(?))", p.email) == ^email
    )
    |> Repo.update_all(
      set: [
        email: nil,
        email_captured_at: nil,
        notify_on_reply: false,
        revoked_at: DateTime.utc_now(:second),
        updated_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp erase_slug_identity!(email, organization_id) do
    threads = from c in Thread, where: c.organization_id == ^organization_id, select: c.id

    claims =
      from s in Custyard.Slug,
        where: s.organization_id == ^organization_id or s.thread_id in subquery(threads),
        where: fragment("lower(trim(?))", s.email) == ^email

    Repo.delete_all(from s in claims, where: s.status in [:claimed, :confirmed])

    from(s in claims, where: s.status == :provisioned)
    |> Repo.update_all(
      set: [email: nil, confirmation_token_hash: nil, updated_at: DateTime.utc_now(:second)]
    )
  end

  defp anonymize_personal_customer!(email, organization_id) do
    from(o in Custyard.Organization,
      where: o.id == ^organization_id and o.identity_kind == :email,
      where: fragment("lower(trim(?))", o.identity_value) == ^email
    )
    |> Repo.update_all(
      set: [
        identity_kind: :manual,
        identity_value: Ecto.UUID.generate(),
        name: "Erased customer",
        domain: nil,
        updated_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp locked_participations(email, organization_id) do
    query = participation_query(email, organization_id)
    query = if @postgres?, do: lock(query, "FOR UPDATE"), else: query

    query
    |> Repo.all()
    |> Enum.map(fn {message, _thread} -> message end)
    |> Enum.reject(&(roles(&1, email) == []))
    |> Enum.split_with(&sender_matches?(&1.sender_email, email))
  end

  defp erase_sent!(%Message{} = message) do
    message
    |> Ecto.Changeset.change(%{
      body: "",
      html_body: nil,
      sender_email: nil,
      to_addresses: [],
      cc_addresses: [],
      reply_to: nil,
      authentication: nil,
      deleted_at: message.deleted_at || DateTime.utc_now(:second)
    })
    |> Repo.update!()
  end

  # The address's own delivery outcomes, on every message in the organization
  # (spec-thread-loop, "Delivery Tracking"). Addresses are stored
  # normalised, so an exact match is enough.
  defp erase_recipient_statuses!(email, organization_id) do
    # SQLite allows no JOIN in DELETE, so the organization's messages come
    # from a subquery.
    message_ids =
      from(m in Message,
        join: c in Thread,
        on: c.id == m.thread_id,
        where: c.organization_id == ^organization_id,
        select: m.id
      )

    from(r in MessageRecipientStatus,
      where: r.message_id in subquery(message_ids) and r.address == ^email
    )
    |> Repo.delete_all()
  end

  defp erase_contact!(email, organization_id) do
    contact_ids =
      from(c in Contact,
        where:
          c.organization_id == ^organization_id and fragment("lower(trim(?))", c.email) == ^email,
        select: c.id
      )
      |> Repo.all()

    {threads, _} =
      from(c in Thread, where: c.contact_id in ^contact_ids)
      |> Repo.update_all(
        set: [subject: @erased_subject, contact_id: nil, updated_at: DateTime.utc_now(:second)]
      )

    from(c in Custyard.PortalCredential, where: c.contact_id in ^contact_ids)
    |> Repo.update_all(set: [contact_id: nil, revoked_at: DateTime.utc_now(:second)])

    {contacts, _} = Repo.delete_all(from(c in Contact, where: c.id in ^contact_ids))
    {threads, contacts}
  end

  defp erase_rejections!(tenant_id, email, organization_id) do
    pattern = "%<#{escape_like(email)}>"

    {count, _} =
      from(r in InboundChannelRejection,
        where:
          r.tenant_id == ^tenant_id and
            (r.organization_id == ^organization_id or is_nil(r.organization_id)) and
            (fragment("lower(trim(?))", r.sender_email) == ^email or
               fragment("lower(trim(?)) LIKE ? ESCAPE '!'", r.sender_email, ^pattern))
      )
      |> Repo.delete_all()

    count
  end

  defp scrub!(%Message{} = message, email) do
    changes = %{
      to_addresses: without(message.to_addresses, email),
      cc_addresses: without(message.cc_addresses, email),
      reply_to: if(same?(message.reply_to, email), do: nil, else: message.reply_to)
    }

    message |> Ecto.Changeset.change(changes) |> Repo.update!()
    true
  end

  defp without(nil, _email), do: []
  defp without(list, email), do: Enum.reject(list, &same?(&1, email))

  defp same?(value, email) when is_binary(value), do: String.downcase(String.trim(value)) == email
  defp same?(_value, _email), do: false

  defp roles(%Message{} = message, email) do
    [
      sender_matches?(message.sender_email, email) && :sender,
      Enum.any?(message.to_addresses || [], &same?(&1, email)) && :to,
      Enum.any?(message.cc_addresses || [], &same?(&1, email)) && :cc,
      same?(message.reply_to, email) && :reply_to
    ]
    |> Enum.filter(& &1)
  end

  # sender_email is stored as the adapter delivered it: bare, or `Name <addr>`.
  defp sender_matches?(sender, email) when is_binary(sender) do
    sender = normalize(sender)
    sender == email or String.ends_with?(sender, "<#{email}>")
  end

  defp sender_matches?(_sender, _email), do: false

  defp normalize(email), do: email |> String.trim() |> String.downcase()

  defp participation_query(email, organization_id) do
    base =
      from m in Message,
        join: c in Thread,
        on: c.id == m.thread_id,
        where: c.organization_id == ^organization_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        select: {m, c}

    if @postgres?,
      do: postgres_participant(base, email),
      else: sqlite_participant(base, email)
  end

  defp postgres_participant(query, email) do
    pattern = "%<#{escape_like(email)}>"

    where(
      query,
      [m],
      fragment("lower(trim(?)) = ?", m.sender_email, ^email) or
        fragment("lower(trim(?)) LIKE ? ESCAPE '!'", m.sender_email, ^pattern) or
        fragment("lower(trim(?)) = ?", m.reply_to, ^email) or
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) a WHERE lower(trim(a)) = ?)",
          m.to_addresses,
          ^email
        ) or
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) a WHERE lower(trim(a)) = ?)",
          m.cc_addresses,
          ^email
        )
    )
  end

  defp sqlite_participant(query, email) do
    pattern = "%<#{escape_like(email)}>"

    where(
      query,
      [m],
      fragment("lower(trim(?)) = ?", m.sender_email, ^email) or
        fragment("lower(trim(?)) LIKE ? ESCAPE '!'", m.sender_email, ^pattern) or
        fragment("lower(trim(?)) = ?", m.reply_to, ^email) or
        fragment(
          "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(trim(value)) = ?)",
          m.to_addresses,
          ^email
        ) or
        fragment(
          "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(trim(value)) = ?)",
          m.cc_addresses,
          ^email
        )
    )
  end

  defp escape_like(email) do
    email
    |> String.replace("!", "!!")
    |> String.replace("%", "!%")
    |> String.replace("_", "!_")
  end

  defp audit!(organization_id, payload) do
    attrs = %{
      event_type: :data_subject_erasure,
      source: "dsar",
      organization_id: organization_id,
      payload: payload
    }

    case AuditEvent.create(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc "True when `email` is a syntactically valid address."
  def valid_email?(email), do: EmailAddress.valid?(email)
end

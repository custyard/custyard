defmodule Custyard.Email.ThreadMatcher do
  @moduledoc """
  Match inbound email to an existing thread inside the receiving tenant.

  An unambiguous header reference preserves the thread's customer identity and
  permits multiparty participants without granting portal credentials. Ambiguous
  references do not merge threads. Subject fallback additionally requires the
  same customer and a sender who already participated.

  A reply the staff forwarded from their Sent folder has lost its headers. It
  is matched by who it was sent to and its subject (`find_for_sent_reply/3`).
  """

  alias Custyard.{Contact, Thread, Message, Organization, Prospect, Repo}
  alias Custyard.Email.{ForwardUnwrapper, SenderMatcher}
  import Ecto.Query

  # Threads that carry email correspondence with a customer.
  @email_sources [:email, :lettermint, :public_intake, :portal]
  @reply_prefix ~r/^\s*(?:(?:re|aw|sv)\s*:\s*)+/iu
  # A recipient with more threads than this is matched on the newest ones.
  @sent_reply_candidates 200

  @doc "Find an email thread by headers within the receiving tenant."
  def find_in_tenant(parsed, tenant_id) when is_integer(tenant_id) do
    with :not_found <- tenant_header_match([parsed[:in_reply_to]], tenant_id, parsed) do
      ids = if is_binary(parsed[:references]), do: String.split(parsed.references), else: []
      tenant_header_match(ids, tenant_id, parsed)
    end
  end

  def find_in_tenant(_parsed, _tenant_id), do: :not_found

  # A message can refer to several unrelated threads (mailing lists, forwards).
  # Ambiguity never silently chooses one customer's thread.
  defp tenant_header_match(ids, tenant_id, parsed) do
    ids = Enum.filter(ids, &(is_binary(&1) and String.trim(&1) != ""))

    from(c in Thread,
      join: m in Message,
      on: m.thread_id == c.id,
      left_join: p in Prospect,
      on: p.thread_id == c.id,
      where: c.tenant_id == ^tenant_id and m.message_id in ^ids,
      where: c.source in ^@email_sources,
      distinct: true,
      limit: 2,
      select: c
    )
    |> eligible_customers(parsed)
    |> Repo.all()
    |> case do
      [thread] -> {:ok, thread}
      [] -> :not_found
      _ambiguous -> :ambiguous
    end
  end

  # A public link has not established a customer relationship yet. Only the
  # captured prospect may turn its email reply into a customer thread; another
  # sender quoting its Message-ID must not claim that anonymous thread.
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
  who has already participated. Only one recent matching thread qualifies.
  New mail with a coincidentally identical subject does not merge.
  """
  def find_by_subject(parsed, organization_id, tenant_id) do
    with subject when is_binary(subject) <- parsed[:subject],
         true <- Regex.match?(~r/^\s*(?:re|aw|sv)\s*:/iu, subject),
         sender when is_binary(sender) <- SenderMatcher.extract_email(parsed[:from]),
         normalized when normalized != "" <- normalize_subject(subject) do
      cutoff = DateTime.utc_now() |> DateTime.add(-30 * 86_400)

      candidates =
        from(c in Thread,
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

  defp sender_participated?(thread, sender) do
    thread = Repo.preload(thread, :contact)

    if thread.contact && thread.contact.email == sender do
      true
    else
      from(m in Message,
        where: m.thread_id == ^thread.id and m.source == :email,
        where: is_nil(m.deleted_at) and m.is_internal_note == false,
        where: is_nil(m.triage_class) or m.triage_class in [:customer, :staff_forward],
        select: m.sender_email
      )
      |> Repo.all()
      |> Enum.any?(&(SenderMatcher.extract_email(&1) == sender))
    end
  end

  @doc """
  Find the thread a staff reply answered when only its recipients and subject
  are known, as for a reply forwarded from the Sent folder.

  `recipients` are the reply's To and Cc addresses, bare and lowercased, in
  the order written. A thread qualifies when its contact, or the prospect of
  a public-intake thread, is one of them and its subject equals `subject`
  once reply and forward prefixes are removed from both. A thread of anyone
  else never matches, whatever its subject.

  The first recipient with a qualifying thread decides. Among that
  recipient's threads an unresolved one comes before a resolved one, then
  the most recently active. One query.
  """
  @spec find_for_sent_reply([String.t()], String.t() | nil, integer()) ::
          {:ok, struct()} | :not_found
  def find_for_sent_reply(recipients, subject, tenant_id)
      when is_list(recipients) and is_integer(tenant_id) do
    wanted = bare_subject(subject)

    if recipients == [] or wanted == "" do
      :not_found
    else
      recipients
      |> sent_reply_candidates(tenant_id)
      |> Enum.filter(fn {thread, _contact, _prospect} ->
        bare_subject(thread.subject) == wanted
      end)
      |> Enum.min_by(&sent_reply_rank(&1, recipients), fn -> nil end)
      |> case do
        {thread, _contact, _prospect} -> {:ok, thread}
        nil -> :not_found
      end
    end
  end

  def find_for_sent_reply(_recipients, _subject, _tenant_id), do: :not_found

  # Subjects are compared in Elixir: the prefixes cannot be removed in SQL.
  defp sent_reply_candidates(recipients, tenant_id) do
    from(c in Thread,
      left_join: ct in Contact,
      on: ct.id == c.contact_id,
      left_join: p in Prospect,
      on: p.thread_id == c.id and is_nil(p.revoked_at),
      where: c.tenant_id == ^tenant_id and c.source in ^@email_sources,
      where: ct.email in ^recipients or p.email in ^recipients,
      order_by: [desc: c.id],
      limit: @sent_reply_candidates,
      select: {c, ct.email, p.email}
    )
    |> Repo.all()
  end

  # Lowest wins: the recipient's place in the list, unresolved before
  # resolved, then the latest activity, then the newest thread.
  defp sent_reply_rank({thread, contact, prospect}, recipients) do
    place = Enum.find_index(recipients, &(&1 in [contact, prospect]))
    resolved = if thread.state == :resolved, do: 1, else: 0

    {place, resolved, -last_activity(thread), -thread.id}
  end

  # The later of the customer's and the staff's last action. A thread nobody
  # has acted on yet counts from when it was created.
  defp last_activity(thread) do
    [thread.last_customer_action_at, thread.last_staff_action_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> thread.inserted_at end)
    |> DateTime.to_unix()
  end

  defp normalize_subject(subject) when is_binary(subject) do
    subject
    |> String.replace(@reply_prefix, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_subject(_subject), do: ""

  # normalize_subject/1 with forward prefixes removed as well, in any order:
  # "Fwd: Re: WG: Invoice" is "invoice".
  defp bare_subject(subject) when is_binary(subject) do
    stripped =
      subject |> String.replace(@reply_prefix, "") |> ForwardUnwrapper.strip_forward_prefix()

    if stripped == subject, do: normalize_subject(subject), else: bare_subject(stripped)
  end

  defp bare_subject(_subject), do: ""

  defp unique_match([thread]), do: {:ok, thread}
  defp unique_match(_none_or_ambiguous), do: :not_found
end

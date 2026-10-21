defmodule Custyard.DataSubjects do
  @moduledoc """
  Data subject requests for people who appear on email messages
  (spec-inbound-channels, Privacy and compliance).

  A contact's own conversations are findable through the contact record. A
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
      the contact-level erasure's job and are left alone; the counts tell
      the operator how many those are.

  `mix custyard.dsar` wraps both for operators until a UI exists.
  Addresses are matched case-insensitively; the audit event written on
  erasure records counts only, never the address.
  """

  import Ecto.Query

  alias Custyard.{AuditEvent, Conversation, EmailAddress, Message, Repo}

  require Logger

  @type role :: :sender | :to | :cc | :reply_to

  @doc """
  Every message in `organization_id` the address appears on, newest first,
  each with the roles the address plays on it.
  """
  @spec participations(String.t(), integer()) :: [
          %{message: Message.t(), conversation: Conversation.t(), roles: [role()]}
        ]
  def participations(email, organization_id) when is_binary(email) do
    email = normalize(email)

    email
    |> participation_query(organization_id)
    |> Repo.all()
    |> Enum.map(fn {message, conversation} ->
      %{message: message, conversation: conversation, roles: roles(message, email)}
    end)
  end

  @doc "Export for a data subject request. See the moduledoc for what is included."
  def export(email, organization_id) when is_binary(email) do
    email = normalize(email)

    messages =
      for %{message: message, conversation: conversation, roles: roles} <-
            participations(email, organization_id) do
        %{
          message_id: message.id,
          conversation_id: conversation.id,
          subject: conversation.subject,
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
  def erase_participation(email, organization_id) when is_binary(email) do
    email = normalize(email)
    found = participations(email, organization_id)

    {sent, received} = Enum.split_with(found, fn %{roles: roles} -> :sender in roles end)

    erased =
      Repo.transaction(fn ->
        Enum.count(received, fn %{message: message} -> scrub!(message, email) end)
      end)

    with {:ok, count} <- erased do
      audit(organization_id, count, length(sent))
      {:ok, %{erased: count, sent_by_subject: length(sent)}}
    end
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
    sender = String.downcase(sender)
    sender == email or String.ends_with?(sender, "<#{email}>")
  end

  defp sender_matches?(_sender, _email), do: false

  defp normalize(email), do: email |> String.trim() |> String.downcase()

  # The recipient arrays are JSON text on SQLite and native arrays on
  # Postgres, so the containment test is adapter-specific. The adapter is
  # compile-time configuration (see Custyard.Repo).
  @postgres? Application.compile_env(:custyard, :repo_adapter, Ecto.Adapters.SQLite3) ==
               Ecto.Adapters.Postgres

  defp participation_query(email, organization_id) do
    base =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: c.organization_id == ^organization_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        select: {m, c}

    if @postgres?,
      do: postgres_participant(base, email),
      else: sqlite_participant(base, email)
  end

  defp postgres_participant(query, email) do
    pattern = "%<#{email}>"

    where(
      query,
      [m],
      fragment("lower(?) = ?", m.sender_email, ^email) or
        fragment("lower(?) LIKE ?", m.sender_email, ^pattern) or
        fragment("lower(?) = ?", m.reply_to, ^email) or
        fragment("EXISTS (SELECT 1 FROM unnest(?) a WHERE lower(a) = ?)", m.to_addresses, ^email) or
        fragment("EXISTS (SELECT 1 FROM unnest(?) a WHERE lower(a) = ?)", m.cc_addresses, ^email)
    )
  end

  defp sqlite_participant(query, email) do
    pattern = "%<#{email}>"

    where(
      query,
      [m],
      fragment("lower(?) = ?", m.sender_email, ^email) or
        fragment("lower(?) LIKE ?", m.sender_email, ^pattern) or
        fragment("lower(?) = ?", m.reply_to, ^email) or
        fragment(
          "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(value) = ?)",
          m.to_addresses,
          ^email
        ) or
        fragment(
          "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(value) = ?)",
          m.cc_addresses,
          ^email
        )
    )
  end

  defp audit(organization_id, erased, sent_by_subject) do
    attrs = %{
      event_type: :data_subject_erasure,
      source: "dsar",
      organization_id: organization_id,
      payload: %{"erased" => erased, "sent_by_subject" => sent_by_subject}
    }

    case AuditEvent.create(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error("DSAR audit event failed: #{inspect(Keyword.keys(changeset.errors))}")
        :ok
    end
  end

  @doc "True when `email` is a syntactically valid address."
  def valid_email?(email), do: EmailAddress.valid?(email)
end

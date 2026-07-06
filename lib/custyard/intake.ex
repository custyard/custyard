defmodule Custyard.Intake do
  @moduledoc """
  Public intake domain: intake-source configuration, anonymous conversation
  creation, resume-token access, and prospect email capture.

  Public-intake conversations carry source `:public_intake`, no organization,
  and no contact. Each has exactly one `Custyard.Prospect` holding the hashed
  resume token; the plaintext token is returned exactly once at creation (and
  again only on rotation) and is never persisted.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias Custyard.{
    Conversation,
    Conversations,
    IntakeSource,
    Message,
    Prospect,
    Repo,
    Scoring
  }

  alias Custyard.Auth.Token
  alias Custyard.Email.{Normalizer, SenderMatcher}

  # Slack-adapter subject derivation precedent: 80-char cap, 77 + "..."
  @subject_max_length 80

  ## Intake sources -----------------------------------------------------------

  @doc """
  List all intake sources, ordered by key.
  """
  def list_sources do
    Repo.all(from s in IntakeSource, order_by: [asc: s.key])
  end

  @doc """
  Get an intake source by id, regardless of enabled state. Returns `nil`
  when not found. Operator UI lookup - the public surface must use
  `get_enabled_source/1`.
  """
  def get_source(id) do
    Repo.get(IntakeSource, id)
  end

  @doc """
  Get an enabled intake source by key.

  Returns `nil` for unknown or disabled keys. Request input is validated by
  table lookup — never converted to an atom.
  """
  def get_enabled_source(key) when is_binary(key) do
    Repo.get_by(IntakeSource, key: key, enabled: true)
  end

  def get_enabled_source(_key), do: nil

  @doc """
  Create an intake source.
  """
  def create_source(attrs) do
    %IntakeSource{}
    |> IntakeSource.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update an intake source.

  The key is immutable after creation (public URL segment and conversation
  provenance): `IntakeSource.update_changeset/2` never casts `:key`, so key
  values in `attrs` are ignored regardless of caller.
  """
  def update_source(%IntakeSource{} = source, attrs) do
    source
    |> IntakeSource.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete an intake source.

  Conversation provenance is unaffected: `conversations.intake_source_key`
  stores the key string, not a foreign key.
  """
  def delete_source(%IntakeSource{} = source) do
    Repo.delete(source)
  end

  ## Conversation creation ----------------------------------------------------

  @doc """
  Create a public-intake conversation from an anonymous submission.

  Validates `source_key` against enabled intake sources by table lookup, then
  atomically creates:

  - the conversation (source `:public_intake`, no organization, no contact,
    subject derived from the first non-empty line of the body)
  - the prospect with a fresh resume token (hash stored, plaintext returned)
  - the first message (source `:prospect`, origin `:public_intake`)

  Post-commit it caches the attention score and broadcasts
  `{:conversation_created, id}` on the `"conversations"` topic only — the
  org-scoped topic is skipped because the organization is nil.

  Returns `{:ok, %{conversation: c, prospect: p, resume_token: token}}` — the
  only place the plaintext resume token is returned — or
  `{:error, :unknown_source}` / `{:error, changeset}`.
  """
  def create_intake_conversation(source_key, message_body, _opts \\ []) do
    case get_enabled_source(source_key) do
      nil ->
        {:error, :unknown_source}

      %IntakeSource{} = source ->
        do_create_intake_conversation(source, message_body)
    end
  end

  defp do_create_intake_conversation(source, message_body) do
    {resume_token, token_hash} = Token.generate()
    body = Normalizer.truncate(message_body, Normalizer.max_body_length())
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversation_changeset =
      Conversation.intake_changeset(%Conversation{}, %{
        subject: derive_subject(body),
        state: :new,
        source: :public_intake,
        intake_source_key: source.key,
        last_customer_action_at: now
      })

    Multi.new()
    |> Multi.insert(:conversation, conversation_changeset)
    |> Multi.insert(:prospect, fn %{conversation: conversation} ->
      Prospect.create_changeset(%Prospect{}, %{
        conversation_id: conversation.id,
        resume_token_hash: token_hash
      })
    end)
    |> Multi.insert(:message, fn %{conversation: conversation} ->
      # sender_email and delivery_status are deliberately nil: there is no
      # sender identity yet, and inbound messages never carry delivery state.
      Message.changeset(%Message{}, %{
        conversation_id: conversation.id,
        source: :prospect,
        origin: :public_intake,
        body: body,
        is_internal_note: false
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{conversation: conversation, prospect: prospect}} ->
        Scoring.calculate_and_cache(conversation.id)

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversations",
          {:conversation_created, conversation.id}
        )

        # No-op while organization_id is nil (broadcast_to_org/2 guard) —
        # public-intake conversations have no org topic until linked.
        Conversations.broadcast_to_org(
          conversation.organization_id,
          {:conversation_created, conversation.id}
        )

        {:ok,
         %{
           conversation: Repo.reload!(conversation),
           prospect: prospect,
           resume_token: resume_token
         }}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Subject derivation: first non-empty line of the body, truncated to 80
  # chars (77 + "..."), mirroring the Slack adapter's precedent.
  defp derive_subject(body) do
    body
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> truncate_subject()
  end

  defp truncate_subject(nil), do: nil

  defp truncate_subject(text) do
    case String.length(text) do
      len when len > @subject_max_length -> String.slice(text, 0, 77) <> "..."
      _ -> text
    end
  end

  ## Resume access ------------------------------------------------------------

  @doc """
  Fetch the conversation a resume token grants access to.

  Hashes the presented token for an indexed lookup; revoked and unknown tokens
  are indistinguishable (`{:error, :not_found}`). Preloads the associations the
  resume view renders (organization, contact, prospect, public messages).
  """
  def get_conversation_by_resume_token(token) when is_binary(token) do
    hash = Token.hash(token)

    prospect =
      Repo.one(
        from p in Prospect,
          where: p.resume_token_hash == ^hash and is_nil(p.revoked_at)
      )

    case prospect do
      nil ->
        {:error, :not_found}

      %Prospect{} = prospect ->
        conversation =
          Conversation
          |> Repo.get!(prospect.conversation_id)
          |> Repo.preload([
            :organization,
            :contact,
            :prospect,
            messages:
              from(m in Message,
                where: m.is_internal_note == false,
                order_by: [asc: m.inserted_at, asc: m.id]
              )
          ])

        {:ok, conversation}
    end
  end

  def get_conversation_by_resume_token(_token), do: {:error, :not_found}

  @doc """
  Rotate a conversation's resume token, invalidating the previous one.

  Returns `{:ok, %{prospect: p, resume_token: token}}` — the only other place
  a plaintext resume token is returned. Rotation does not clear revocation.
  """
  def rotate_resume_token(%Conversation{} = conversation) do
    case get_prospect(conversation) do
      nil ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        {resume_token, token_hash} = Token.generate()

        with {:ok, prospect} <-
               prospect |> Prospect.rotate_token_changeset(token_hash) |> Repo.update() do
          {:ok, %{prospect: prospect, resume_token: resume_token}}
        end
    end
  end

  @doc """
  Revoke resume access for a conversation. Operator-initiated; the resume
  token stops resolving once `revoked_at` is set.
  """
  def revoke_resume_access(%Conversation{} = conversation) do
    case get_prospect(conversation) do
      nil ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        prospect
        |> Prospect.revoke_changeset(now)
        |> Repo.update()
    end
  end

  @doc """
  Set the prospect's reply-notification preference.

  Revoked prospects are rejected with the same `{:error, :no_prospect}` as
  missing ones — revocation removes write access entirely.
  """
  def set_notification(%Conversation{} = conversation, notify?) when is_boolean(notify?) do
    case get_prospect(conversation) do
      nil ->
        {:error, :no_prospect}

      %Prospect{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        prospect
        |> Prospect.notification_changeset(notify?)
        |> Repo.update()
    end
  end

  ## Email capture and linking ------------------------------------------------

  @doc """
  Capture a prospect's email on a public-intake conversation and link it to a
  known identity when resolution finds one.

  One transaction: write-once email capture (`{:error, :already_captured}` on
  a second attempt; revoked prospects are rejected as `{:error, :no_prospect}`,
  indistinguishable from missing ones), lookup-only resolution via
  `SenderMatcher.resolve/1`, then linking per outcome — a contact match sets
  BOTH `contact_id` and `organization_id` in one changeset (nothing else
  validates the pair), a domain match sets the organization only, and `:none`
  touches nothing. A conversation already linked to an organization is never
  re-linked: existing (operator) linkage wins, though the email is still
  captured.

  Post-commit: rescore plus `"conversations"` and `"conversation:{id}"`
  broadcasts; the org-scoped topic fires only when the conversation linked.

  Enumeration-neutral: returns `{:ok, conversation}` to callers regardless of
  link outcome — the response never reveals whether the email matched.

  ## Options

    * `:notify` - reply-notification consent captured alongside the email
      (default `false`)
  """
  def capture_email(%Conversation{} = conversation, email, opts \\ []) do
    notify? = Keyword.get(opts, :notify, false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      case Repo.get_by(Prospect, conversation_id: conversation.id) do
        nil ->
          Repo.rollback(:no_prospect)

        # Revoked prospects lose write access even through a still-live
        # handle (e.g. a LiveView mounted before revocation). Reuses
        # :no_prospect so revoked and missing stay indistinguishable.
        %Prospect{revoked_at: revoked} when not is_nil(revoked) ->
          Repo.rollback(:no_prospect)

        %Prospect{email: existing} when not is_nil(existing) ->
          Repo.rollback(:already_captured)

        %Prospect{} = prospect ->
          capture_and_link(conversation, prospect, %{
            email: email,
            email_captured_at: now,
            notify_on_reply: notify?
          })
      end
    end)
    |> case do
      {:ok, conversation} ->
        perform_capture_side_effects(conversation)
        {:ok, Repo.reload!(conversation)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_and_link(conversation, prospect, attrs) do
    case prospect |> Prospect.capture_email_changeset(attrs) |> Repo.update() do
      {:ok, prospect} ->
        case link_conversation(conversation, SenderMatcher.resolve(prospect.email)) do
          {:ok, conversation} -> conversation
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # Existing linkage wins: an operator (or earlier flow) that already linked
  # the conversation to an organization must not be silently overridden by
  # identity derived from anonymous public input.
  defp link_conversation(%Conversation{organization_id: org_id} = conversation, _resolution)
       when not is_nil(org_id) do
    {:ok, conversation}
  end

  # Contact match: both FKs set in ONE changeset — nothing else validates
  # that the contact/organization pair is consistent.
  defp link_conversation(conversation, {:contact, contact}) do
    conversation
    |> Conversation.changeset(%{
      contact_id: contact.id,
      organization_id: contact.organization_id
    })
    |> Repo.update()
  end

  defp link_conversation(conversation, {:organization, organization}) do
    conversation
    |> Conversation.changeset(%{organization_id: organization.id})
    |> Repo.update()
  end

  defp link_conversation(conversation, :none), do: {:ok, conversation}

  defp perform_capture_side_effects(conversation) do
    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:conversation_updated, conversation.id}
    )

    # Fires only when the capture linked the conversation to an organization
    # (broadcast_to_org/2 skips nil org ids).
    Conversations.broadcast_to_org(
      conversation.organization_id,
      {:conversation_updated, conversation.id}
    )

    :ok
  end

  defp get_prospect(%Conversation{id: conversation_id}) do
    Repo.get_by(Prospect, conversation_id: conversation_id)
  end
end

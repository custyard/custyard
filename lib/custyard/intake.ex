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
  The intake source passive pages pair with: the first enabled active-mode
  source, ordered by key — the deterministic choice until explicit pairing
  exists in the schema. Returns `nil` when no enabled active source exists.
  """
  def first_enabled_active_source do
    Repo.one(
      from s in IntakeSource,
        where: s.enabled == true and s.mode == :active,
        order_by: [asc: s.key],
        limit: 1
    )
  end

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
      # message_id is synthetic — see generate_prospect_message_id/1.
      Message.changeset(%Message{}, %{
        conversation_id: conversation.id,
        source: :prospect,
        origin: :public_intake,
        body: body,
        is_internal_note: false,
        message_id: generate_prospect_message_id(conversation.id)
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
  Whether a resume token currently resolves: same predicate as
  `get_conversation_by_resume_token/1` (hash match, not revoked) without
  loading the conversation or its preloads.

  For surfaces that only need validity — the cookie refresh in
  `CustyardWeb.Plugs.ResumeCookie` and the intake-page resume banner —
  not the thread.
  """
  def resume_token_valid?(token) when is_binary(token) do
    hash = Token.hash(token)

    Repo.exists?(
      from p in Prospect,
        where: p.resume_token_hash == ^hash and is_nil(p.revoked_at)
    )
  end

  def resume_token_valid?(_token), do: false

  @doc """
  Add a prospect reply to a public-intake conversation via the resume surface.

  Mirrors the established inbound semantics (the webhook pipeline's
  reactivation and the portal reply path): the message carries source
  `:prospect` and origin `:public_intake` with `sender_email` and
  `delivery_status` deliberately nil; a reply on a waiting/dormant/resolved
  conversation reactivates it to `:active`; `last_customer_action_at` is
  always touched. Post-commit: rescore plus guarded broadcasts (the
  org-scoped topic fires only when the conversation is linked).

  The conversation and prospect are re-read so a revocation after the caller
  loaded its handle still blocks the write: revoked and missing prospects are
  both `{:error, :no_prospect}`, indistinguishable by design.

  ## Options

    * `:token_hash` - the hash of the resume token the caller authenticated
      with. When present, the write is refused (`{:error, :no_prospect}`)
      unless it still matches the prospect's stored hash — token rotation
      must strip write access from handles minted under the previous token.
      Callers that did not authenticate by token (the intake POST that just
      created it) omit the option.
  """
  def add_prospect_reply(%Conversation{id: conversation_id}, body, opts \\ [])
      when is_binary(body) do
    conversation = Repo.get(Conversation, conversation_id)
    prospect = conversation && Repo.get_by(Prospect, conversation_id: conversation_id)

    cond do
      is_nil(conversation) or is_nil(prospect) ->
        {:error, :no_prospect}

      not is_nil(prospect.revoked_at) ->
        {:error, :no_prospect}

      not token_hash_current?(prospect, opts) ->
        {:error, :no_prospect}

      true ->
        do_add_prospect_reply(conversation, body)
    end
  end

  defp do_add_prospect_reply(conversation, body) do
    body = Normalizer.truncate(body, Normalizer.max_body_length())
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message_changeset =
      Message.changeset(%Message{}, %{
        conversation_id: conversation.id,
        source: :prospect,
        origin: :public_intake,
        body: body,
        is_internal_note: false,
        message_id: generate_prospect_message_id(conversation.id)
      })

    Multi.new()
    |> Multi.insert(:message, message_changeset)
    |> Multi.update(:conversation, reactivate_changeset(conversation, now))
    |> Repo.transaction()
    |> case do
      {:ok, %{conversation: conversation, message: message}} ->
        perform_reply_side_effects(conversation)
        {:ok, %{conversation: conversation, message: message}}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Enforces the `:token_hash` option shared by the resume-surface writes:
  # when the caller presents the credential hash it authenticated with, the
  # prospect's stored hash must still match, otherwise the token rotated
  # underneath a still-mounted socket and the handle has lost access.
  # Callers without the option skip the check.
  defp token_hash_current?(%Prospect{resume_token_hash: current}, opts) do
    case Keyword.fetch(opts, :token_hash) do
      {:ok, presented} -> presented == current
      :error -> true
    end
  end

  # Synthetic RFC 5322 Message-ID for prospect web messages. The intake
  # surface has no real email Message-ID, but operator replies thread
  # In-Reply-To/References off the last customer message's message_id
  # (Email.Outbound), so a nil id here would break threading in the
  # prospect's inbox. Mirrors Conversations.generate_outbound_message_id/1.
  defp generate_prospect_message_id(conversation_id) do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    domain = Application.get_env(:custyard, :outbound_email_domain, "custyard.local")
    "<#{unique}.c#{conversation_id}@#{domain}>"
  end

  # A customer action on a waiting/dormant/resolved conversation reactivates
  # it — mirrors the webhook pipeline's maybe_reactivate and the portal reply
  # path (which also updates last_customer_action_at in the same write).
  defp reactivate_changeset(conversation, now) do
    attrs =
      if conversation.state in [:waiting, :dormant, :resolved] do
        %{state: :active, last_customer_action_at: now}
      else
        %{last_customer_action_at: now}
      end

    Conversation.changeset(conversation, attrs)
  end

  defp perform_reply_side_effects(conversation) do
    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    # No-op while organization_id is nil (broadcast_to_org/2 guard).
    Conversations.broadcast_to_org(
      conversation.organization_id,
      {:conversation_updated, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )

    :ok
  end

  @doc """
  Rotate a conversation's resume token, invalidating the previous one.

  Returns `{:ok, %{prospect: p, resume_token: token}}` — the only other place
  a plaintext resume token is returned. Rotation does not clear revocation.

  Post-commit it broadcasts `{:resume_access_changed, id}` on the
  `"conversation:{id}"` topic so resume views mounted under the old token
  re-authenticate and shut down instead of streaming past the rotation.
  """
  def rotate_resume_token(%Conversation{} = conversation) do
    case get_prospect(conversation) do
      nil ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        {resume_token, token_hash} = Token.generate()

        with {:ok, prospect} <-
               prospect |> Prospect.rotate_token_changeset(token_hash) |> Repo.update() do
          broadcast_resume_access_changed(conversation.id)
          {:ok, %{prospect: prospect, resume_token: resume_token}}
        end
    end
  end

  @doc """
  Revoke resume access for a conversation. Operator-initiated; the resume
  token stops resolving once `revoked_at` is set.

  Broadcasts the same `{:resume_access_changed, id}` as rotation so mounted
  resume views re-authenticate and shut down.
  """
  def revoke_resume_access(%Conversation{} = conversation) do
    case get_prospect(conversation) do
      nil ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        with {:ok, prospect} <- prospect |> Prospect.revoke_changeset(now) |> Repo.update() do
          broadcast_resume_access_changed(conversation.id)
          {:ok, prospect}
        end
    end
  end

  # Resume views subscribe to "conversation:{id}"; this tells them the
  # credential state changed (rotation or revocation) so the read side —
  # an already-mounted socket receiving operator replies over PubSub —
  # gets closed off, not just the writes.
  defp broadcast_resume_access_changed(conversation_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation_id}",
      {:resume_access_changed, conversation_id}
    )

    :ok
  end

  @doc """
  Set the prospect's reply-notification preference.

  Revoked prospects are rejected with the same `{:error, :no_prospect}` as
  missing ones — revocation removes write access entirely. Accepts the same
  `:token_hash` option as `add_prospect_reply/3`: a stale hash (rotated
  token) is refused as `{:error, :no_prospect}`.

  A successful flip broadcasts `{:conversation_updated, id}` on the
  conversation topic so already-mounted operator views recompute reply
  deliverability (consent advisory, delivery expectations) without a manual
  refresh.
  """
  def set_notification(%Conversation{} = conversation, notify?, opts \\ [])
      when is_boolean(notify?) do
    case get_prospect(conversation) do
      nil ->
        {:error, :no_prospect}

      %Prospect{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        if token_hash_current?(prospect, opts) do
          prospect
          |> Prospect.notification_changeset(notify?)
          |> Repo.update()
          |> broadcast_notification_change(conversation.id)
        else
          {:error, :no_prospect}
        end
    end
  end

  # A consent flip must reach already-mounted operator views: ConversationLive
  # handles {:conversation_updated, id} on the conversation topic by reloading,
  # which recomputes the reply-deliverability assigns. The consent gates in
  # Conversations.send_reply/3 and Email.Outbound.deliver/1 re-read the DB
  # regardless — this broadcast keeps the UI honest, not the policy.
  defp broadcast_notification_change({:ok, prospect}, conversation_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation_id}",
      {:conversation_updated, conversation_id}
    )

    {:ok, prospect}
  end

  defp broadcast_notification_change(error, _conversation_id), do: error

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
    * `:token_hash` - same semantics as `add_prospect_reply/3`: a stale hash
      (rotated token) is refused as `{:error, :no_prospect}`, checked before
      the write-once guard so a rotated-out handle cannot learn whether an
      email was captured
  """
  def capture_email(%Conversation{} = conversation, email, opts \\ []) do
    notify? = Keyword.get(opts, :notify, false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      case capturable_prospect(conversation.id, opts) do
        {:ok, prospect} ->
          capture_and_link(conversation, prospect, %{
            email: email,
            email_captured_at: now,
            notify_on_reply: notify?
          })

        {:error, reason} ->
          Repo.rollback(reason)
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

  # Loads the prospect eligible for email capture, inside the transaction.
  # Revoked prospects (write access removed even through a still-live handle,
  # e.g. a LiveView mounted before revocation) and stale token hashes (token
  # rotated underneath a mounted socket) both reuse :no_prospect so all three
  # failure classes stay indistinguishable; the stale-hash check runs BEFORE
  # the write-once guard so a rotated-out handle cannot learn whether an
  # email was captured.
  defp capturable_prospect(conversation_id, opts) do
    case Repo.get_by(Prospect, conversation_id: conversation_id) do
      nil ->
        {:error, :no_prospect}

      %Prospect{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        cond do
          not token_hash_current?(prospect, opts) -> {:error, :no_prospect}
          not is_nil(prospect.email) -> {:error, :already_captured}
          true -> {:ok, prospect}
        end
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

  @doc """
  Fetch the prospect row for a conversation. Returns `nil` when none exists.

  Public so the resume surface can re-read prospect state (captured email,
  notification preference) after a mutation without reaching for `Repo`.
  """
  def get_prospect(%Conversation{id: conversation_id}) do
    Repo.get_by(Prospect, conversation_id: conversation_id)
  end
end

defmodule Custyard.Intake do
  @moduledoc """
  Public intake domain: intake-source configuration, anonymous thread
  creation, access-token access, and prospect email capture.

  Public-intake threads carry source `:public_intake`, no organization,
  and no contact. Each has exactly one `Custyard.Prospect` holding the hashed
  access token; the plaintext token is returned exactly once at creation (and
  again only on rotation) and is never persisted.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias Custyard.{
    Thread,
    Threads,
    IntakeSource,
    Message,
    Prospect,
    Repo,
    Scoring,
    Slugs
  }

  alias Custyard.Auth.Token
  alias Custyard.Email.{Normalizer, SenderMatcher}
  alias Custyard.Intake.ArrivalEmail

  # Slack-adapter subject derivation precedent: 80-char cap, 77 + "..."
  @subject_max_length 80

  ## Intake sources -----------------------------------------------------------

  @doc """
  List all intake sources, ordered by key.
  """
  def list_sources(%Custyard.Scope{tenant_id: tenant_id} = scope) do
    if Custyard.Scope.current_staff(scope),
      do: Repo.all(from s in IntakeSource, where: s.tenant_id == ^tenant_id, order_by: s.key),
      else: []
  end

  def get_source(%Custyard.Scope{tenant_id: tenant_id} = scope, id) do
    if Custyard.Scope.current_staff(scope),
      do: Repo.get_by(IntakeSource, tenant_id: tenant_id, id: id)
  end

  @doc """
  Get an enabled intake source by key.

  Returns `nil` for unknown or disabled keys. Request input is validated by
  table lookup — never converted to an atom.
  """
  def get_enabled_source(key, tenant_id) when is_binary(key) do
    Repo.get_by(IntakeSource, key: key, tenant_id: tenant_id, enabled: true)
  end

  def get_enabled_source(_key, _tenant_id), do: nil

  @doc """
  Get an intake source by key, regardless of enabled state. Returns `nil`
  for unknown keys and non-binary input.

  Provenance lookup for prospect surfaces: `threads.intake_source_key`
  stores the key string (not a foreign key), so a thread's source may
  be disabled or deleted after creation — the branded link on an existing
  thread survives a disable (the source still exists) and disappears on
  delete. Public intake entry must keep using `get_enabled_source/1`.
  """
  def get_source_by_key(key, tenant_id) when is_binary(key) do
    Repo.get_by(IntakeSource, key: key, tenant_id: tenant_id)
  end

  def get_source_by_key(_key, _tenant_id), do: nil

  @doc """
  The intake source passive pages pair with: the first enabled active-mode
  source, ordered by key — the deterministic choice until explicit pairing
  exists in the schema. Returns `nil` when no enabled active source exists.
  """
  def first_enabled_active_source(tenant_id) do
    Repo.one(
      from s in IntakeSource,
        where: s.enabled == true and s.mode == :active and s.tenant_id == ^tenant_id,
        order_by: [asc: s.key],
        limit: 1
    )
  end

  @doc """
  Create an intake source.
  """
  def create_source(%Custyard.Scope{} = scope, attrs) do
    with_source_admin(scope, fn ->
      attrs =
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
        |> Map.put("tenant_id", scope.tenant_id)

      %IntakeSource{} |> IntakeSource.changeset(attrs) |> Repo.insert()
    end)
  end

  @doc """
  Update an intake source.

  The key is immutable after creation (public URL segment and thread
  provenance): `IntakeSource.update_changeset/2` never casts `:key`, so key
  values in `attrs` are ignored regardless of caller.
  """
  def update_source(%Custyard.Scope{} = scope, %IntakeSource{} = source, attrs) do
    with_source_admin(scope, fn ->
      case get_source(scope, source.id) do
        nil -> {:error, :not_found}
        current -> current |> IntakeSource.update_changeset(attrs) |> Repo.update()
      end
    end)
  end

  @doc """
  Delete an intake source.

  Thread provenance is unaffected: `threads.intake_source_key`
  stores the key string, not a foreign key.
  """
  def delete_source(%Custyard.Scope{} = scope, %IntakeSource{} = source) do
    with_source_admin(scope, fn ->
      case get_source(scope, source.id) do
        nil -> {:error, :not_found}
        current -> Repo.delete(current)
      end
    end)
  end

  defp with_source_admin(scope, fun) do
    Repo.transaction(fn ->
      staff =
        scope.staff_id &&
          Custyard.StaffAccess.lock_current(%Custyard.StaffAccount{id: scope.staff_id})

      if staff && staff.tenant_id == scope.tenant_id && staff.role == "admin" &&
           Custyard.StaffAccount.session_claim_matches?(staff, scope.session_claim) &&
           Custyard.Tenants.active?(scope.tenant_id) do
        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:unauthorized)
      end
    end)
  end

  ## Thread creation ----------------------------------------------------

  @doc """
  Create a public-intake thread from an anonymous submission.

  Validates `source_key` against enabled intake sources by table lookup, then
  atomically creates:

  - the thread (source `:public_intake`, no organization, no contact,
    subject derived from the first non-empty line of the body)
  - the prospect with a fresh access token (hash stored, plaintext returned)
  - the first message (source `:prospect`, origin `:public_intake`)

  Post-commit it caches the attention score and broadcasts
  `{:thread_created, id}` on the `"threads"` topic only — the
  org-scoped topic is skipped because the organization is nil.

  Returns `{:ok, %{thread: c, prospect: p, access_token: token}}` — the
  only place the plaintext access token is returned — or
  `{:error, :unknown_source}` / `{:error, changeset}`.
  """
  def create_intake_thread(source_key, message_body, opts) do
    case get_enabled_source(source_key, Keyword.fetch!(opts, :tenant_id)) do
      nil ->
        {:error, :unknown_source}

      %IntakeSource{} = source ->
        do_create_intake_thread(source, message_body)
    end
  end

  defp do_create_intake_thread(source, message_body) do
    {access_token, token_hash} = Token.generate()
    body = Normalizer.truncate(message_body, Normalizer.max_body_length())
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    thread_changeset =
      Thread.intake_changeset(%Thread{}, %{
        subject: derive_subject(body),
        state: :new,
        source: :public_intake,
        intake_source_key: source.key,
        tenant_id: source.tenant_id,
        last_customer_action_at: now
      })

    Multi.new()
    |> Multi.insert(:thread, thread_changeset)
    |> Multi.insert(:prospect, fn %{thread: thread} ->
      Prospect.create_changeset(%Prospect{}, %{
        thread_id: thread.id,
        access_token_hash: token_hash
      })
    end)
    |> Multi.insert(:message, fn %{thread: thread} ->
      # sender_email and delivery_status are deliberately nil: there is no
      # sender identity yet, and inbound messages never carry delivery state.
      # message_id is synthetic — see generate_prospect_message_id/1.
      Message.changeset(%Message{}, %{
        thread_id: thread.id,
        tenant_id: thread.tenant_id,
        source: :prospect,
        origin: :public_intake,
        body: body,
        is_internal_note: false,
        message_id: generate_prospect_message_id(thread.id)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{thread: thread, prospect: prospect}} ->
        Scoring.calculate_and_cache(thread.id)

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "threads",
          {:thread_created, thread.id}
        )

        # No-op while organization_id is nil (broadcast_to_org/2 guard) —
        # public-intake threads have no org topic until linked.
        Threads.broadcast_to_org(
          thread.organization_id,
          {:thread_created, thread.id}
        )

        # Out-of-band arrival signal: the broadcasts above reach only
        # LiveViews that are already open. Result deliberately ignored —
        # everything above is committed, and ArrivalEmail owns its own
        # gating, rate limiting, and failure logging.
        _ = ArrivalEmail.send_arrival(thread, source, body)

        {:ok,
         %{
           thread: Repo.reload!(thread),
           prospect: prospect,
           access_token: access_token
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

  ## Thread access ------------------------------------------------------------

  @doc """
  Fetch the thread a access token grants access to.

  Hashes the presented token for an indexed lookup; revoked and unknown tokens
  are indistinguishable (`{:error, :not_found}`). Preloads the associations the
  thread view renders (organization, contact, prospect, public messages).
  """
  def get_thread_by_access_token(token, tenant_id)
      when is_binary(token) and is_integer(tenant_id) do
    hash = Token.hash(token)

    prospect =
      Repo.one(
        from p in Prospect,
          join: t in Custyard.Tenant,
          on: t.id == p.tenant_id,
          where: p.tenant_id == ^tenant_id and t.status == "active",
          where: p.access_token_hash == ^hash and is_nil(p.revoked_at)
      )

    case prospect do
      nil ->
        {:error, :not_found}

      %Prospect{} = prospect ->
        case Repo.get_by(Thread, id: prospect.thread_id, tenant_id: tenant_id) do
          nil ->
            {:error, :not_found}

          thread ->
            thread =
              Repo.preload(thread, [
                :organization,
                :contact,
                :prospect,
                messages:
                  from(m in Message,
                    where: m.is_internal_note == false,
                    order_by: [asc: m.inserted_at, asc: m.id]
                  )
              ])

            {:ok, thread}
        end
    end
  end

  def get_thread_by_access_token(_token, _tenant_id), do: {:error, :not_found}

  @doc """
  Whether a access token currently resolves: same predicate as
  `get_thread_by_access_token/1` (hash match, not revoked) without
  loading the thread or its preloads.

  For surfaces that only need validity — the cookie refresh in
  `CustyardWeb.Plugs.ThreadCookie` and the intake-page thread banner —
  not the thread.
  """
  def access_token_valid?(token, tenant_id) when is_binary(token) and is_integer(tenant_id) do
    hash = Token.hash(token)

    Repo.exists?(
      from p in Prospect,
        join: t in Custyard.Tenant,
        on: t.id == p.tenant_id,
        where: p.tenant_id == ^tenant_id and t.status == "active",
        where: p.access_token_hash == ^hash and is_nil(p.revoked_at)
    )
  end

  def access_token_valid?(_token, _tenant_id), do: false

  @doc """
  Add a prospect reply to a public-intake thread via the thread surface.

  Mirrors the established inbound semantics (the webhook pipeline's
  reactivation and the portal reply path): the message carries source
  `:prospect` and origin `:public_intake` with `sender_email` and
  `delivery_status` deliberately nil; a reply on a waiting/dormant/resolved
  thread reactivates it to `:active`; `last_customer_action_at` is
  always touched. Post-commit: rescore plus guarded broadcasts (the
  org-scoped topic fires only when the thread is linked).

  The prospect is re-read and re-checked inside the same transaction as the
  write, so a revocation or rotation racing the caller's handle still blocks
  it: revoked and missing prospects are both `{:error, :no_prospect}`,
  indistinguishable by design.

  A reply whose trimmed body is identical to the prospect's most recent
  message in the thread is refused with `{:error, :duplicate_message}`
  — prod testing produced runs of identical messages from double-submits.
  Only the single latest prospect-authored message is compared, so resending
  earlier content stays legitimate.

  ## Options

    * `:token_hash` - the hash of the access token the caller authenticated
      with. When present, the write is refused (`{:error, :no_prospect}`)
      unless it still matches the prospect's stored hash — token rotation
      must strip write access from handles minted under the previous token.
      Callers that did not authenticate by token (the intake POST that just
      created it) omit the option.
  """
  def add_prospect_reply(%Thread{id: thread_id}, body, opts \\ [])
      when is_binary(body) do
    case Repo.get(Thread, thread_id) do
      nil -> {:error, :no_prospect}
      thread -> do_add_prospect_reply(thread, body, opts)
    end
  end

  defp do_add_prospect_reply(thread, body, opts) do
    body = Normalizer.truncate(body, Normalizer.max_body_length())
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message_changeset =
      Message.changeset(%Message{}, %{
        thread_id: thread.id,
        tenant_id: thread.tenant_id,
        source: :prospect,
        origin: :public_intake,
        body: body,
        is_internal_note: false,
        message_id: generate_prospect_message_id(thread.id)
      })

    Multi.new()
    |> Multi.run(:prospect, fn _repo, _changes -> authorized_prospect(thread.id, opts) end)
    |> Multi.run(:duplicate, fn _repo, _changes ->
      if duplicate_of_last_prospect_message?(thread.id, body) do
        {:error, :duplicate_message}
      else
        {:ok, :unique}
      end
    end)
    |> Multi.insert(:message, message_changeset)
    |> Multi.update(:thread, reactivate_changeset(thread, now))
    |> Repo.transaction()
    |> case do
      {:ok, %{thread: thread, message: message}} ->
        perform_reply_side_effects(thread)
        {:ok, %{thread: thread, message: message}}

      {:error, :prospect, reason, _changes} ->
        {:error, reason}

      {:error, :duplicate, reason, _changes} ->
        {:error, reason}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Double-submit guard: whether `body` (trimmed) matches the prospect's most
  # recent message in the thread. Deliberately compares only the single
  # latest prospect-authored message — staff messages never participate,
  # and content older than the latest prospect message may be resent. Runs
  # inside the reply transaction so it serializes with the insert.
  defp duplicate_of_last_prospect_message?(thread_id, body) do
    last_body =
      Repo.one(
        from m in Message,
          where: m.thread_id == ^thread_id and m.source == :prospect,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: 1,
          select: m.body
      )

    is_binary(last_body) and String.trim(last_body) == String.trim(body)
  end

  # Enforces the `:token_hash` option shared by the thread-surface writes:
  # when the caller presents the credential hash it authenticated with, the
  # prospect's stored hash must still match, otherwise the token rotated
  # underneath a still-mounted socket and the handle has lost access.
  # Callers without the option skip the check.
  defp token_hash_current?(%Prospect{access_token_hash: current}, opts) do
    case Keyword.fetch(opts, :token_hash) do
      {:ok, presented} -> presented == current
      :error -> true
    end
  end

  # Synthetic RFC 5322 Message-ID for prospect web messages. The intake
  # surface has no real email Message-ID, but staff replies thread
  # In-Reply-To/References off the last customer message's message_id
  # (Email.Outbound), so a nil id here would break threading in the
  # prospect's inbox. Mirrors Threads.generate_outbound_message_id/1.
  defp generate_prospect_message_id(thread_id) do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    domain = Application.get_env(:custyard, :outbound_email_domain, "custyard.local")
    "<#{unique}.c#{thread_id}@#{domain}>"
  end

  # Loads the prospect eligible to act under the presented token, inside the
  # caller's transaction — mirrors capturable_prospect/2 so a concurrent
  # rotation or revocation between the check and the write can't let a
  # stale/revoked token slip through.
  defp authorized_prospect(thread_id, opts) do
    case Repo.get_by(Prospect, thread_id: thread_id) do
      nil ->
        {:error, :no_prospect}

      %Prospect{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        if token_hash_current?(prospect, opts) do
          {:ok, prospect}
        else
          {:error, :no_prospect}
        end
    end
  end

  # A customer action on a waiting/dormant/resolved thread reactivates
  # it — mirrors the webhook pipeline's maybe_reactivate and the portal reply
  # path (which also updates last_customer_action_at in the same write).
  defp reactivate_changeset(thread, now) do
    attrs =
      if thread.state in [:waiting, :dormant, :resolved] do
        %{state: :active, last_customer_action_at: now}
      else
        %{last_customer_action_at: now}
      end

    Thread.changeset(thread, attrs)
  end

  defp perform_reply_side_effects(thread) do
    Scoring.calculate_and_cache(thread.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "threads",
      {:thread_updated, thread.id}
    )

    # No-op while organization_id is nil (broadcast_to_org/2 guard).
    Threads.broadcast_to_org(
      thread.organization_id,
      {:thread_updated, thread.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread.id}",
      {:message_added, thread.id}
    )

    :ok
  end

  @doc """
  Rotate a thread's access token, invalidating the previous one.

  Returns `{:ok, %{prospect: p, access_token: token}}` — the only other place
  a plaintext access token is returned. Revoked prospects are rejected with
  the same `{:error, :no_prospect}` as missing ones.

  Post-commit it broadcasts `{:thread_access_changed, id}` on the
  `"thread:{id}"` topic so thread views mounted under the old token
  re-authenticate and shut down instead of streaming past the rotation.
  """
  def rotate_access_token(%Thread{} = thread) do
    case get_prospect(thread) do
      nil ->
        {:error, :no_prospect}

      %Prospect{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        {access_token, token_hash} = Token.generate()

        with {:ok, prospect} <-
               prospect |> Prospect.rotate_token_changeset(token_hash) |> Repo.update() do
          broadcast_thread_access_changed(thread.id)
          {:ok, %{prospect: prospect, access_token: access_token}}
        end
    end
  end

  @doc """
  Revoke thread access for a thread. Staff-initiated; the access
  token stops resolving once `revoked_at` is set.

  Broadcasts the same `{:thread_access_changed, id}` as rotation so mounted
  thread views re-authenticate and shut down.
  """
  def revoke_thread_access(%Thread{} = thread) do
    case get_prospect(thread) do
      nil ->
        {:error, :no_prospect}

      %Prospect{} = prospect ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          case prospect |> Prospect.revoke_changeset(now) |> Repo.update() do
            {:ok, prospect} ->
              # Revocation is the abuse control. A pending claim stays
              # confirmable from the emailed link after it, and a confirmed
              # claim never expires, so the revoked prospect would otherwise
              # keep (or still win) the name. Release it in the same
              # transaction; confirming the old link then finds nothing.
              Slugs.release_claim_for_thread(thread.id)
              prospect

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, prospect} ->
            broadcast_thread_access_changed(thread.id)
            {:ok, prospect}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Thread views subscribe to "thread:{id}"; this tells them the
  # credential state changed (rotation or revocation) so the read side —
  # an already-mounted socket receiving staff replies over PubSub —
  # gets closed off, not just the writes.
  defp broadcast_thread_access_changed(thread_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread_id}",
      {:thread_access_changed, thread_id}
    )

    :ok
  end

  @doc """
  Set the prospect's reply-notification preference.

  Revoked prospects are rejected with the same `{:error, :no_prospect}` as
  missing ones — revocation removes write access entirely. Accepts the same
  `:token_hash` option as `add_prospect_reply/3`: a stale hash (rotated
  token) is refused as `{:error, :no_prospect}`. The check and the update run
  inside the same transaction, so a revocation or rotation racing the
  caller's handle still blocks the write.

  A successful flip broadcasts `{:thread_updated, id}` on the
  thread topic so already-mounted staff views recompute reply
  deliverability (consent advisory, delivery expectations) without a manual
  refresh.
  """
  def set_notification(%Thread{id: thread_id}, notify?, opts \\ [])
      when is_boolean(notify?) do
    result =
      Repo.transaction(fn ->
        case authorized_prospect(thread_id, opts) do
          {:ok, prospect} ->
            case prospect |> Prospect.notification_changeset(notify?) |> Repo.update() do
              {:ok, prospect} -> prospect
              {:error, changeset} -> Repo.rollback(changeset)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    with {:ok, prospect} <- result do
      broadcast_notification_change({:ok, prospect}, thread_id)
    end

    result
  end

  # A consent flip must reach already-mounted staff views: ThreadLive
  # handles {:thread_updated, id} on the thread topic by reloading,
  # which recomputes the reply-deliverability assigns. The consent gates in
  # Threads.send_reply/3 and Email.Outbound.deliver/1 re-read the DB
  # regardless — this broadcast keeps the UI honest, not the policy.
  defp broadcast_notification_change({:ok, prospect}, thread_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread_id}",
      {:thread_updated, thread_id}
    )

    {:ok, prospect}
  end

  defp broadcast_notification_change(error, _thread_id), do: error

  ## Email capture and linking ------------------------------------------------

  @doc """
  Capture a prospect's email on a public-intake thread and link it to a
  known identity when resolution finds one.

  One transaction: write-once email capture (`{:error, :already_captured}` on
  a second attempt; revoked prospects are rejected as `{:error, :no_prospect}`,
  indistinguishable from missing ones), lookup-only resolution via
  `SenderMatcher.resolve/1`, then linking per outcome — a contact match sets
  BOTH `contact_id` and `organization_id` in one changeset (nothing else
  validates the pair), a domain match sets the organization only, and `:none`
  touches nothing. A thread already linked to an organization is never
  re-linked: existing (staff) linkage wins, though the email is still
  captured.

  Post-commit: rescore plus `"threads"` and `"thread:{id}"`
  broadcasts; the org-scoped topic fires only when the thread linked.

  Enumeration-neutral: returns `{:ok, thread}` to callers regardless of
  link outcome — the response never reveals whether the email matched.

  ## Options

    * `:notify` - reply-notification consent captured alongside the email
      (default `false`)
    * `:token_hash` - same semantics as `add_prospect_reply/3`: a stale hash
      (rotated token) is refused as `{:error, :no_prospect}`, checked before
      the write-once guard so a rotated-out handle cannot learn whether an
      email was captured
  """
  def capture_email(%Thread{} = thread, email, opts \\ []) do
    notify? = Keyword.get(opts, :notify, false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      case capturable_prospect(thread.id, opts) do
        {:ok, prospect} ->
          capture_and_link(thread, prospect, %{
            email: email,
            email_captured_at: now,
            notify_on_reply: notify?
          })

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, thread} ->
        perform_capture_side_effects(thread)
        {:ok, Repo.reload!(thread)}

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
  defp capturable_prospect(thread_id, opts) do
    case Repo.get_by(Prospect, thread_id: thread_id) do
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

  defp capture_and_link(thread, prospect, attrs) do
    case prospect |> Prospect.capture_email_changeset(attrs) |> Repo.update() do
      {:ok, prospect} ->
        # Linking is now a conditional UPDATE that always reports success
        # (a lost DB-side race returns the thread untouched), so there
        # is no changeset error to roll back here.
        {:ok, thread} =
          link_thread(
            thread,
            SenderMatcher.resolve_existing(prospect.email, thread.tenant_id)
          )

        thread

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # Existing linkage wins: a staff (or earlier flow) that already linked
  # the thread to an organization must not be silently overridden by
  # identity derived from anonymous public input.
  defp link_thread(%Thread{organization_id: org_id} = thread, _resolution)
       when not is_nil(org_id) do
    {:ok, thread}
  end

  # Contact match: both FKs set in ONE write — nothing else validates that
  # the contact/organization pair is consistent. Conditional on
  # `organization_id IS NULL` at the DB, not just the in-memory struct: a
  # socket mounted before a staff ran Organizations.convert_prospect/3
  # still carries organization_id: nil, so a plain update-by-PK could clobber
  # the just-converted link and orphan the new org. The DB guard means a
  # concurrent link wins (0 rows) and this write is a no-op.
  defp link_thread(%Thread{id: id} = thread, {:contact, contact}) do
    conditional_link(thread, id,
      contact_id: contact.id,
      organization_id: contact.organization_id
    )
  end

  defp link_thread(%Thread{id: id} = thread, {:organization, organization}) do
    conditional_link(thread, id, organization_id: organization.id)
  end

  defp link_thread(thread, outcome) when outcome in [:none, :ambiguous],
    do: {:ok, thread}

  # Race-safe conditional link: `WHERE id = ? AND organization_id IS NULL`.
  # On count == 1 the fields are patched onto the in-memory struct so the
  # post-commit side effects (org-scoped broadcast) see the new linkage
  # without a re-read; capture_email/3 reloads for the value it returns. On
  # count == 0 a concurrent link already won, so the stale struct is returned
  # untouched and its link is left intact.
  defp conditional_link(thread, id, fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    set = Keyword.put(fields, :updated_at, now)

    {count, _} =
      Repo.update_all(
        from(c in Thread, where: c.id == ^id and is_nil(c.organization_id)),
        set: set
      )

    if count == 1 do
      {:ok, struct(thread, set)}
    else
      {:ok, thread}
    end
  end

  defp perform_capture_side_effects(thread) do
    Scoring.calculate_and_cache(thread.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "threads",
      {:thread_updated, thread.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread.id}",
      {:thread_updated, thread.id}
    )

    # Fires only when the capture linked the thread to an organization
    # (broadcast_to_org/2 skips nil org ids).
    Threads.broadcast_to_org(
      thread.organization_id,
      {:thread_updated, thread.id}
    )

    :ok
  end

  @doc """
  Fetch the prospect row for a thread. Returns `nil` when none exists.

  Public so the thread surface can re-read prospect state (captured email,
  notification preference) after a mutation without reaching for `Repo`.
  """
  def get_prospect(%Thread{id: thread_id}) do
    Repo.get_by(Prospect, thread_id: thread_id)
  end
end

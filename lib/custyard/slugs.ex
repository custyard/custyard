defmodule Custyard.Slugs do
  @moduledoc """
  The slug registry: claim, confirm, expire, and release organization slugs.

  One `slugs` table owns the entire namespace (see
  docs/design/design-decisions-public-intake.md §Slug Registry). `available`
  means no row exists: expiry and operator release DELETE rows, and the
  unique index on `slug` arbitrates every race — two parties claiming the
  same name concurrently resolve to one insert and one changeset error,
  never a 500.

  Expiry is enforced twice: lazily inside `claim/3`'s transaction (an
  expired claimed row on the requested slug — or on the claiming
  conversation — is deleted before the insert), and by the hourly
  `Custyard.Slugs.ClaimExpiry` sweep. Confirmation tokens are stored
  hash-only via `Custyard.Auth.Token`; the plaintext leaves this module
  exactly once per generation.

  Promotion to `provisioned` (`promote/2`) is the only path allowed to write
  `organization_id`; it is called exclusively from
  `Custyard.Organizations.convert_prospect/2`, inside the conversion
  transaction.
  """

  import Ecto.Query

  alias Custyard.Auth.Token
  alias Custyard.{Conversation, Organization, Repo, Settings, Slug}

  @max_live_claims_per_email 3

  @doc "Per-anchor-email bound on live (claimed or confirmed) rows."
  def max_live_claims_per_email, do: @max_live_claims_per_email

  @doc """
  Claim `slug_text` for `conversation`, anchored to `email`.

  One transaction: lazy expiry first (an expired claimed row holding the
  requested slug — or held by this conversation — is deleted so dead rows
  never block a live claim), then the per-email bound (at most
  #{@max_live_claims_per_email} live claimed/confirmed rows per anchor
  email, counted inside the transaction), then the insert. The unique
  indexes arbitrate races: a lost race surfaces as a changeset error on
  `:slug` (taken) or `:conversation_id` (one live claim per conversation).

  `expires_at` = now + `Settings.get_intake_config().slug_claim_ttl_hours`.

  Returns `{:ok, slug_record, confirmation_token}` — the ONLY place the
  plaintext confirmation token for a new claim exists; only its hash is
  stored — or `{:error, changeset}`.
  """
  def claim(slug_text, email, %Conversation{} = conversation) do
    ttl_hours = Settings.get_intake_config().slug_claim_ttl_hours
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {token, hash} = Token.generate()

    changeset =
      Slug.claim_changeset(%Slug{}, %{
        slug: slug_text,
        email: email,
        conversation_id: conversation.id,
        expires_at: DateTime.add(now, ttl_hours, :hour),
        confirmation_token_hash: hash
      })

    if changeset.valid? do
      insert_claim(changeset, now, token)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp insert_claim(changeset, now, token) do
    slug_text = Ecto.Changeset.get_field(changeset, :slug)
    email = Ecto.Changeset.get_field(changeset, :email)
    conversation_id = Ecto.Changeset.get_field(changeset, :conversation_id)

    Repo.transaction(fn ->
      release_expired_claims(slug_text, conversation_id, now)

      if live_claim_count_for_email(email, now) >= @max_live_claims_per_email do
        changeset
        |> Ecto.Changeset.add_error(:email, "already anchors the maximum number of live claims")
        |> Map.put(:action, :insert)
        |> Repo.rollback()
      else
        case Repo.insert(changeset) do
          {:ok, slug} -> slug
          {:error, invalid_changeset} -> Repo.rollback(invalid_changeset)
        end
      end
    end)
    |> case do
      {:ok, slug} -> {:ok, slug, token}
      {:error, reason} -> {:error, reason}
    end
  end

  # Lazy expiry inside the claim transaction: dead (expired, still-claimed)
  # rows must not block either unique index — neither the slug being
  # claimed by a new party nor the one-claim-per-conversation rule when the
  # conversation's own earlier claim lapsed.
  defp release_expired_claims(slug_text, conversation_id, now) do
    Repo.delete_all(
      from s in Slug,
        where:
          s.status == :claimed and s.expires_at <= ^now and
            (s.slug == ^slug_text or s.conversation_id == ^conversation_id)
    )
  end

  defp live_claim_count_for_email(email, now) do
    Repo.aggregate(
      from(s in Slug,
        where:
          s.email == ^email and
            (s.status == :confirmed or (s.status == :claimed and s.expires_at > ^now))
      ),
      :count
    )
  end

  @doc """
  Look up the live claim a confirmation token points at — the GET peek.

  ZERO state change: mail-scanner prefetch must never consume the token.
  Expired, consumed, and unknown tokens are all `{:error, :invalid}`,
  indistinguishable by design.
  """
  def peek(token) when is_binary(token) do
    hash = Token.hash(token)
    now = DateTime.utc_now()

    case Repo.one(
           from s in Slug,
             where:
               s.confirmation_token_hash == ^hash and s.status == :claimed and
                 s.expires_at > ^now
         ) do
      nil -> {:error, :invalid}
      %Slug{} = slug -> {:ok, slug}
    end
  end

  def peek(_token), do: {:error, :invalid}

  @doc """
  Consume a confirmation token: race-safe conditional UPDATE.

  `WHERE confirmation_token_hash = hash AND status = 'claimed' AND
  expires_at > now` — sets status `confirmed`, stamps `confirmed_at`, and
  clears both the token hash (single-use) and `expires_at` (confirmed
  claims do not expire; the operator releases them). Zero rows updated —
  invalid, expired, already-used, or purged — is `{:error, :invalid}`:
  one failure shape, no validity oracle.
  """
  def confirm(token) when is_binary(token) do
    hash = Token.hash(token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.one(from s in Slug, where: s.confirmation_token_hash == ^hash, select: s.id) do
      nil ->
        {:error, :invalid}

      id ->
        {count, _} =
          Repo.update_all(
            from(s in Slug,
              where:
                s.id == ^id and s.confirmation_token_hash == ^hash and
                  s.status == :claimed and s.expires_at > ^now
            ),
            set: [
              status: :confirmed,
              confirmed_at: now,
              confirmation_token_hash: nil,
              expires_at: nil,
              updated_at: now
            ]
          )

        if count == 1, do: {:ok, Repo.get!(Slug, id)}, else: {:error, :invalid}
    end
  end

  def confirm(_token), do: {:error, :invalid}

  @doc """
  Rotate the confirmation token on a live claim (the resend path: only the
  hash is stored, so re-sending means minting a new token).

  Conditional on `status = 'claimed' AND expires_at > now` so a confirmed
  or expired claim can never grow a fresh token. Returns
  `{:ok, slug, token}` with the plaintext exactly once, or
  `{:error, :invalid}`.
  """
  def rotate_confirmation_token(%Slug{id: id}) do
    {token, hash} = Token.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(s in Slug, where: s.id == ^id and s.status == :claimed and s.expires_at > ^now),
        set: [confirmation_token_hash: hash, updated_at: now]
      )

    if count == 1, do: {:ok, Repo.get!(Slug, id), token}, else: {:error, :invalid}
  end

  @doc """
  Operator release: DELETE a claimed or confirmed row, returning the slug
  to `available`.

  Provisioned rows are refused (`{:error, :provisioned}`) — a provisioned
  slug is an organization's portal identity and is released only by
  organization deletion. The delete is conditional on status so a row
  promoted between load and click is never deleted (`{:error, :not_found}`).
  """
  def release(%Slug{status: :provisioned}), do: {:error, :provisioned}

  def release(%Slug{id: id} = slug) do
    {count, _} =
      Repo.delete_all(from s in Slug, where: s.id == ^id and s.status in [:claimed, :confirmed])

    if count == 1, do: {:ok, slug}, else: {:error, :not_found}
  end

  @doc """
  Promote a conversation's confirmed claim to `provisioned`, linking it to
  `organization`. Called only from `Custyard.Organizations.convert_prospect/2`,
  inside its conversion transaction.

  Race-safe conditional UPDATE: `WHERE conversation_id = ? AND status =
  'confirmed'`. A claim that was released, expired away, never confirmed, or
  already promoted between load and this call updates zero rows —
  `{:error, :not_found}`, which the caller treats as "nothing to promote,"
  not a conversion failure: a prospect can convert without ever having
  claimed a slug.

  Returns `{:ok, :provisioned}` rather than the updated row — the sole
  caller only needs to know whether the promotion happened, so this skips
  the extra `SELECT` a re-fetch would cost on every conversion.
  """
  def promote(%Conversation{id: conversation_id}, %Organization{id: organization_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(s in Slug, where: s.conversation_id == ^conversation_id and s.status == :confirmed),
        set: [status: :provisioned, organization_id: organization_id, updated_at: now]
      )

    case count do
      1 -> {:ok, :provisioned}
      0 -> {:error, :not_found}
    end
  end

  @doc """
  Whether a slug is available to claim: no row holds it, counting an
  expired-but-unswept claimed row as absent (lazy expiry would delete it).

  Not exposed as a public probe endpoint — the claim attempt itself is the
  availability check, and its changeset error is the only oracle.
  """
  def available?(slug_text) when is_binary(slug_text) do
    normalized = slug_text |> String.trim() |> String.downcase()
    now = DateTime.utc_now()

    not Repo.exists?(
      from s in Slug,
        where:
          s.slug == ^normalized and
            (s.status in [:confirmed, :provisioned] or
               (s.status == :claimed and s.expires_at > ^now))
    )
  end

  @doc """
  The conversation's live claim: a non-expired claimed row, or a
  confirmed/provisioned one. Expired unswept rows are invisible here —
  the claim panel offers a fresh claim instead.
  """
  def get_claim_for_conversation(conversation_id) do
    now = DateTime.utc_now()

    Repo.one(
      from s in Slug,
        where:
          s.conversation_id == ^conversation_id and
            (s.status in [:confirmed, :provisioned] or
               (s.status == :claimed and s.expires_at > ^now))
    )
  end

  @doc """
  All registry rows for the operator view, newest first.
  """
  def list_slugs do
    Repo.all(from s in Slug, order_by: [desc: s.inserted_at, desc: s.id])
  end

  @doc """
  Fetch a slug row by id. Returns `nil` when not found.
  """
  def get_slug(id), do: Repo.get(Slug, id)

  @doc """
  Delete every claimed row whose expiry has passed as of `now` (injectable
  clock). Returns the count deleted. Only the slug rows die — conversations
  are untouched.

  Called hourly by `Custyard.Slugs.ClaimExpiry`; public so tests drive it
  deterministically.
  """
  def delete_expired_claims(now \\ DateTime.utc_now()) do
    {count, _} =
      Repo.delete_all(from s in Slug, where: s.status == :claimed and s.expires_at <= ^now)

    count
  end
end

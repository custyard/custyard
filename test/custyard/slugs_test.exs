defmodule Custyard.SlugsTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.Auth.Token
  alias Custyard.{Conversation, Settings, Slug, Slugs}

  defp intake_conversation do
    insert_conversation(source: :public_intake)
  end

  defp expire!(%Slug{} = slug, hours_ago \\ 1) do
    past =
      DateTime.utc_now()
      |> DateTime.add(-hours_ago, :hour)
      |> DateTime.truncate(:second)

    {1, _} =
      Repo.update_all(
        from(s in Slug, where: s.id == ^slug.id),
        set: [expires_at: past]
      )

    Repo.get!(Slug, slug.id)
  end

  describe "claim/3" do
    test "claims a slug, storing only the token hash" do
      conversation = intake_conversation()

      assert {:ok, %Slug{} = slug, token} =
               Slugs.claim("acme-corp", "buyer@example.com", conversation)

      assert slug.slug == "acme-corp"
      assert slug.status == :claimed
      assert slug.email == "buyer@example.com"
      assert slug.conversation_id == conversation.id
      assert is_nil(slug.organization_id)
      assert is_nil(slug.confirmed_at)

      # Plaintext returned exactly once; only the hash is at rest.
      assert is_binary(token)
      assert slug.confirmation_token_hash == Token.hash(token)
      refute slug.confirmation_token_hash == token
    end

    test "expires_at honors the configured TTL" do
      {:ok, _} = Settings.update_intake_config(%{slug_claim_ttl_hours: 5})
      conversation = intake_conversation()

      {:ok, slug, _token} = Slugs.claim("ttl-check", "buyer@example.com", conversation)

      expected = DateTime.add(DateTime.utc_now(), 5, :hour)
      assert_in_delta DateTime.to_unix(slug.expires_at), DateTime.to_unix(expected), 60
    end

    test "normalizes slug and email" do
      conversation = intake_conversation()

      {:ok, slug, _token} = Slugs.claim("  AcMe  ", "  Buyer@EXAMPLE.com ", conversation)

      assert slug.slug == "acme"
      assert slug.email == "buyer@example.com"
    end

    test "a second party claiming a live slug gets a changeset error, not a 500" do
      first = intake_conversation()
      second = intake_conversation()

      {:ok, _slug, _token} = Slugs.claim("contested", "first@example.com", first)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("contested", "second@example.com", second)

      assert "is already claimed" in errors_on(changeset).slug
      assert Repo.aggregate(Slug, :count) == 1
    end

    test "one live claim per conversation" do
      conversation = intake_conversation()

      {:ok, _slug, _token} = Slugs.claim("first-name", "buyer@example.com", conversation)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("second-name", "buyer@example.com", conversation)

      assert "already has a slug claim" in errors_on(changeset).conversation_id
    end

    test "an expired claim is lazily re-claimable by a NEW party in one transaction" do
      first = intake_conversation()
      second = intake_conversation()

      {:ok, stale, _token} = Slugs.claim("recycled", "first@example.com", first)
      expire!(stale)

      assert {:ok, fresh, _token} = Slugs.claim("recycled", "second@example.com", second)

      assert fresh.conversation_id == second.id
      assert fresh.email == "second@example.com"
      # The dead row is gone — one row holds the slug.
      assert Repo.aggregate(Slug, :count) == 1
      refute Repo.get(Slug, stale.id)
    end

    test "a conversation whose own claim expired can claim a different slug" do
      conversation = intake_conversation()

      {:ok, stale, _token} = Slugs.claim("old-name", "buyer@example.com", conversation)
      expire!(stale)

      assert {:ok, fresh, _token} = Slugs.claim("new-name", "buyer@example.com", conversation)

      assert fresh.slug == "new-name"
      refute Repo.get(Slug, stale.id)
    end

    test "at most 3 live claims per anchor email" do
      for i <- 1..3 do
        {:ok, _slug, _token} =
          Slugs.claim("bounded-#{i}", "greedy@example.com", intake_conversation())
      end

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("bounded-4", "greedy@example.com", intake_conversation())

      assert "already anchors the maximum number of live claims" in errors_on(changeset).email

      # A different email is unaffected.
      assert {:ok, _slug, _token} =
               Slugs.claim("bounded-4", "modest@example.com", intake_conversation())
    end

    test "expired claims do not count toward the per-email bound" do
      for i <- 1..3 do
        {:ok, slug, _token} =
          Slugs.claim("stale-#{i}", "greedy@example.com", intake_conversation())

        expire!(slug)
      end

      assert {:ok, _slug, _token} =
               Slugs.claim("fresh-one", "greedy@example.com", intake_conversation())
    end

    test "confirmed claims count toward the per-email bound" do
      for i <- 1..3 do
        {:ok, _slug, token} =
          Slugs.claim("held-#{i}", "greedy@example.com", intake_conversation())

        {:ok, _confirmed} = Slugs.confirm(token)
      end

      assert {:error, %Ecto.Changeset{}} =
               Slugs.claim("held-4", "greedy@example.com", intake_conversation())
    end

    test "invalid input returns a changeset error without touching the registry" do
      conversation = intake_conversation()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("operator", "buyer@example.com", conversation)

      assert "is reserved" in errors_on(changeset).slug
      assert Repo.aggregate(Slug, :count) == 0
    end
  end

  describe "confirm/1 and peek/1" do
    setup do
      conversation = intake_conversation()
      {:ok, slug, token} = Slugs.claim("confirm-me", "buyer@example.com", conversation)
      %{conversation: conversation, slug: slug, token: token}
    end

    test "peek returns the claim without any state change", %{slug: slug, token: token} do
      assert {:ok, peeked} = Slugs.peek(token)
      assert peeked.id == slug.id

      # Scanner-style repeated peeks consume nothing.
      assert {:ok, _} = Slugs.peek(token)
      assert Repo.get!(Slug, slug.id).status == :claimed
      assert Repo.get!(Slug, slug.id).confirmation_token_hash == slug.confirmation_token_hash
    end

    test "confirm consumes the token exactly once", %{slug: slug, token: token} do
      assert {:ok, confirmed} = Slugs.confirm(token)

      assert confirmed.id == slug.id
      assert confirmed.status == :confirmed
      assert confirmed.confirmed_at
      assert is_nil(confirmed.confirmation_token_hash)
      assert is_nil(confirmed.expires_at)

      # Single-use: the second confirm and any peek are uniformly invalid.
      assert {:error, :invalid} = Slugs.confirm(token)
      assert {:error, :invalid} = Slugs.peek(token)
    end

    test "expired tokens neither peek nor confirm", %{slug: slug, token: token} do
      expire!(slug)

      assert {:error, :invalid} = Slugs.peek(token)
      assert {:error, :invalid} = Slugs.confirm(token)
      assert Repo.get!(Slug, slug.id).status == :claimed
    end

    test "unknown and malformed tokens are invalid" do
      assert {:error, :invalid} = Slugs.peek("no-such-token")
      assert {:error, :invalid} = Slugs.confirm("no-such-token")
      assert {:error, :invalid} = Slugs.peek(nil)
      assert {:error, :invalid} = Slugs.confirm(nil)
    end
  end

  describe "rotate_confirmation_token/1" do
    test "mints a new token and invalidates the old one" do
      {:ok, slug, old_token} =
        Slugs.claim("rotate-me", "buyer@example.com", intake_conversation())

      assert {:ok, rotated, new_token} = Slugs.rotate_confirmation_token(slug)

      assert rotated.confirmation_token_hash == Token.hash(new_token)
      refute new_token == old_token
      assert {:error, :invalid} = Slugs.confirm(old_token)
      assert {:ok, _} = Slugs.confirm(new_token)
    end

    test "refuses confirmed and expired claims" do
      {:ok, _slug, token} = Slugs.claim("done-deal", "buyer@example.com", intake_conversation())
      {:ok, confirmed} = Slugs.confirm(token)

      assert {:error, :invalid} = Slugs.rotate_confirmation_token(confirmed)

      {:ok, stale, _token} = Slugs.claim("stale-deal", "buyer@example.com", intake_conversation())
      stale = expire!(stale)

      assert {:error, :invalid} = Slugs.rotate_confirmation_token(stale)
    end
  end

  describe "release/1" do
    test "releases a claimed slug and re-opens it for claiming" do
      conversation = intake_conversation()
      {:ok, slug, _token} = Slugs.claim("give-back", "buyer@example.com", conversation)

      assert {:ok, _released} = Slugs.release(slug)
      refute Repo.get(Slug, slug.id)

      # The conversation survives — only the slug row dies.
      assert Repo.get(Conversation, conversation.id)

      # Available again, claimable by anyone.
      assert Slugs.available?("give-back")

      assert {:ok, _slug, _token} =
               Slugs.claim("give-back", "other@example.com", intake_conversation())
    end

    test "releases a confirmed slug" do
      {:ok, _slug, token} = Slugs.claim("give-back-2", "buyer@example.com", intake_conversation())
      {:ok, confirmed} = Slugs.confirm(token)

      assert {:ok, _released} = Slugs.release(confirmed)
      assert Slugs.available?("give-back-2")
    end

    test "refuses provisioned slugs — that is org-deletion territory" do
      org = insert_organization()

      provisioned =
        insert_slug(
          slug: "provisioned-co",
          status: :provisioned,
          organization_id: org.id,
          confirmation_token_hash: nil,
          expires_at: nil
        )

      assert {:error, :provisioned} = Slugs.release(provisioned)
      assert Repo.get(Slug, provisioned.id)
    end
  end

  describe "promote/2" do
    test "promotes a confirmed claim to provisioned, linking the organization" do
      conversation = intake_conversation()
      {:ok, _slug, token} = Slugs.claim("promote-me", "buyer@example.com", conversation)
      {:ok, _confirmed} = Slugs.confirm(token)
      org = insert_organization()

      assert {:ok, promoted} = Slugs.promote(conversation, org)
      assert promoted.status == :provisioned
      assert promoted.organization_id == org.id
    end

    test "an unconfirmed (merely claimed) row is not promoted" do
      conversation = intake_conversation()
      {:ok, _slug, _token} = Slugs.claim("still-pending", "buyer@example.com", conversation)
      org = insert_organization()

      assert {:error, :not_found} = Slugs.promote(conversation, org)
      assert Repo.get_by!(Slug, conversation_id: conversation.id).status == :claimed
    end

    test "a conversation with no claim at all is not a failure" do
      conversation = intake_conversation()
      org = insert_organization()

      assert {:error, :not_found} = Slugs.promote(conversation, org)
    end

    test "an already-provisioned row is not re-promoted" do
      conversation = intake_conversation()
      {:ok, _slug, token} = Slugs.claim("once-only", "buyer@example.com", conversation)
      {:ok, _confirmed} = Slugs.confirm(token)
      org = insert_organization()
      other_org = insert_organization()

      assert {:ok, _} = Slugs.promote(conversation, org)
      assert {:error, :not_found} = Slugs.promote(conversation, other_org)
      assert Repo.get_by!(Slug, conversation_id: conversation.id).organization_id == org.id
    end
  end

  describe "available?/1" do
    test "no row means available" do
      assert Slugs.available?("never-claimed")
    end

    test "live and confirmed claims block; expired ones do not" do
      {:ok, _slug, token} = Slugs.claim("checking", "buyer@example.com", intake_conversation())
      refute Slugs.available?("checking")
      refute Slugs.available?("  CHECKING  ")

      {:ok, _} = Slugs.confirm(token)
      refute Slugs.available?("checking")

      {:ok, stale, _} = Slugs.claim("lapsing", "buyer@example.com", intake_conversation())
      expire!(stale)
      assert Slugs.available?("lapsing")
    end
  end

  describe "get_claim_for_conversation/1" do
    test "returns the live claim and hides expired ones" do
      conversation = intake_conversation()
      assert is_nil(Slugs.get_claim_for_conversation(conversation.id))

      {:ok, slug, token} = Slugs.claim("my-live-claim", "buyer@example.com", conversation)
      assert Slugs.get_claim_for_conversation(conversation.id).id == slug.id

      {:ok, _} = Slugs.confirm(token)
      assert Slugs.get_claim_for_conversation(conversation.id).status == :confirmed

      other = intake_conversation()
      {:ok, stale, _} = Slugs.claim("other-claim", "other@example.com", other)
      expire!(stale)
      assert is_nil(Slugs.get_claim_for_conversation(other.id))
    end
  end

  describe "expiry" do
    test "expiry releases the slug only; the conversation and its messages persist" do
      conversation = intake_conversation()
      insert_message(conversation_id: conversation.id, source: :email, body: "still here")

      {:ok, slug, _token} = Slugs.claim("fleeting", "buyer@example.com", conversation)
      expire!(slug)

      assert Slugs.delete_expired_claims() == 1
      refute Repo.get(Slug, slug.id)
      assert Repo.get(Conversation, conversation.id)

      assert Repo.aggregate(
               from(m in Custyard.Message, where: m.conversation_id == ^conversation.id),
               :count
             ) == 1
    end
  end

  describe "database CHECK constraints (raw inserts under ecto_sqlite3)" do
    # The pairing invariant lives in the DB because SQLite cannot ADD a
    # CONSTRAINT after creation — these prove the boolean-equality CHECK
    # actually fires, bypassing all application validation.

    test "provisioned without an organization raises" do
      assert {:error, %Exqlite.Error{message: message}} =
               Repo.query(
                 "INSERT INTO slugs (slug, status, inserted_at, updated_at) " <>
                   "VALUES ('bad-provisioned', 'provisioned', '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
               )

      assert message =~ "CHECK"
    end

    test "non-provisioned with an organization raises" do
      org = insert_organization()

      for status <- ["claimed", "confirmed"] do
        assert {:error, %Exqlite.Error{message: message}} =
                 Repo.query(
                   "INSERT INTO slugs (slug, status, organization_id, inserted_at, updated_at) " <>
                     "VALUES ('bad-#{status}', '#{status}', #{org.id}, '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
                 )

        assert message =~ "CHECK"
      end
    end

    test "provisioned with an organization inserts (the CHECK passes both ways)" do
      org = insert_organization()

      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO slugs (slug, status, organization_id, inserted_at, updated_at) " <>
                   "VALUES ('good-provisioned', 'provisioned', #{org.id}, '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
               )
    end

    test "unknown status values raise on the status CHECK" do
      assert {:error, %Exqlite.Error{message: message}} =
               Repo.query(
                 "INSERT INTO slugs (slug, status, inserted_at, updated_at) " <>
                   "VALUES ('bad-status', 'tombstoned', '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
               )

      assert message =~ "CHECK"
    end
  end
end

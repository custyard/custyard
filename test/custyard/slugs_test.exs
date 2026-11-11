defmodule Custyard.SlugsTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.Auth.Token
  alias Custyard.{Thread, Settings, Slug, Slugs}

  defp intake_thread do
    insert_thread(source: :public_intake)
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
      thread = intake_thread()

      assert {:ok, %Slug{} = slug, token} =
               Slugs.claim("acme-corp", "buyer@example.com", thread)

      assert slug.slug == "acme-corp"
      assert slug.status == :claimed
      assert slug.email == "buyer@example.com"
      assert slug.thread_id == thread.id
      assert is_nil(slug.organization_id)
      assert is_nil(slug.confirmed_at)

      # Plaintext returned exactly once; only the hash is at rest.
      assert is_binary(token)
      assert slug.confirmation_token_hash == Token.hash(token)
      refute slug.confirmation_token_hash == token
    end

    test "expires_at honors the configured TTL" do
      {:ok, _} =
        Settings.update_intake_config(
          Custyard.Factory.staff_scope(Custyard.Factory.factory_tenant_id()),
          %{
            slug_claim_ttl_hours: 5
          }
        )

      thread = intake_thread()

      {:ok, slug, _token} = Slugs.claim("ttl-check", "buyer@example.com", thread)

      expected = DateTime.add(DateTime.utc_now(), 5, :hour)
      assert_in_delta DateTime.to_unix(slug.expires_at), DateTime.to_unix(expected), 60
    end

    test "normalizes slug and email" do
      thread = intake_thread()

      {:ok, slug, _token} = Slugs.claim("  AcMe  ", "  Buyer@EXAMPLE.com ", thread)

      assert slug.slug == "acme"
      assert slug.email == "buyer@example.com"
    end

    test "a second party claiming a live slug gets a changeset error, not a 500" do
      first = intake_thread()
      second = intake_thread()

      {:ok, _slug, _token} = Slugs.claim("contested", "first@example.com", first)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("contested", "second@example.com", second)

      assert "is already claimed" in errors_on(changeset).slug
      assert Repo.aggregate(Slug, :count) == 1
    end

    test "one live claim per thread" do
      thread = intake_thread()

      {:ok, _slug, _token} = Slugs.claim("first-name", "buyer@example.com", thread)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("second-name", "buyer@example.com", thread)

      assert "already has a slug claim" in errors_on(changeset).thread_id
    end

    test "an expired claim is lazily re-claimable by a NEW party in one transaction" do
      first = intake_thread()
      second = intake_thread()

      {:ok, stale, _token} = Slugs.claim("recycled", "first@example.com", first)
      expire!(stale)

      assert {:ok, fresh, _token} = Slugs.claim("recycled", "second@example.com", second)

      assert fresh.thread_id == second.id
      assert fresh.email == "second@example.com"
      # The dead row is gone — one row holds the slug.
      assert Repo.aggregate(Slug, :count) == 1
      refute Repo.get(Slug, stale.id)
    end

    test "a thread whose own claim expired can claim a different slug" do
      thread = intake_thread()

      {:ok, stale, _token} = Slugs.claim("old-name", "buyer@example.com", thread)
      expire!(stale)

      assert {:ok, fresh, _token} = Slugs.claim("new-name", "buyer@example.com", thread)

      assert fresh.slug == "new-name"
      refute Repo.get(Slug, stale.id)
    end

    test "at most 3 live claims per anchor email" do
      for i <- 1..3 do
        {:ok, _slug, _token} =
          Slugs.claim("bounded-#{i}", "greedy@example.com", intake_thread())
      end

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("bounded-4", "greedy@example.com", intake_thread())

      assert "already anchors the maximum number of live claims" in errors_on(changeset).email

      # A different email is unaffected.
      assert {:ok, _slug, _token} =
               Slugs.claim("bounded-4", "modest@example.com", intake_thread())
    end

    test "expired claims do not count toward the per-email bound" do
      for i <- 1..3 do
        {:ok, slug, _token} =
          Slugs.claim("stale-#{i}", "greedy@example.com", intake_thread())

        expire!(slug)
      end

      assert {:ok, _slug, _token} =
               Slugs.claim("fresh-one", "greedy@example.com", intake_thread())
    end

    test "confirmed claims count toward the per-email bound" do
      for i <- 1..3 do
        {:ok, _slug, token} =
          Slugs.claim("held-#{i}", "greedy@example.com", intake_thread())

        {:ok, _confirmed} = confirm_claim(token)
      end

      assert {:error, %Ecto.Changeset{}} =
               Slugs.claim("held-4", "greedy@example.com", intake_thread())
    end

    test "invalid input returns a changeset error without touching the registry" do
      thread = intake_thread()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Slugs.claim("staff", "buyer@example.com", thread)

      assert "is reserved" in errors_on(changeset).slug
      assert Repo.aggregate(Slug, :count) == 0
    end
  end

  describe "confirm/1 and peek/1" do
    setup do
      thread = intake_thread()
      {:ok, slug, token} = Slugs.claim("confirm-me", "buyer@example.com", thread)
      %{thread: thread, slug: slug, token: token}
    end

    test "peek returns the claim without any state change", %{slug: slug, token: token} do
      assert {:ok, peeked} = peek_claim(token)
      assert peeked.id == slug.id

      # Scanner-style repeated peeks consume nothing.
      assert {:ok, _} = peek_claim(token)
      assert Repo.get!(Slug, slug.id).status == :claimed
      assert Repo.get!(Slug, slug.id).confirmation_token_hash == slug.confirmation_token_hash
    end

    test "confirm consumes the token exactly once", %{slug: slug, token: token} do
      assert {:ok, confirmed} = confirm_claim(token)

      assert confirmed.id == slug.id
      assert confirmed.status == :confirmed
      assert confirmed.confirmed_at
      assert is_nil(confirmed.confirmation_token_hash)
      assert is_nil(confirmed.expires_at)

      # Single-use: the second confirm and any peek are uniformly invalid.
      assert {:error, :invalid} = confirm_claim(token)
      assert {:error, :invalid} = peek_claim(token)
    end

    test "expired tokens neither peek nor confirm", %{slug: slug, token: token} do
      expire!(slug)

      assert {:error, :invalid} = peek_claim(token)
      assert {:error, :invalid} = confirm_claim(token)
      assert Repo.get!(Slug, slug.id).status == :claimed
    end

    test "unknown and malformed tokens are invalid" do
      assert {:error, :invalid} = peek_claim("no-such-token")
      assert {:error, :invalid} = confirm_claim("no-such-token")
      assert {:error, :invalid} = peek_claim(nil)
      assert {:error, :invalid} = confirm_claim(nil)
    end
  end

  describe "rotate_confirmation_token/1" do
    test "mints a new token and invalidates the old one" do
      {:ok, slug, old_token} =
        Slugs.claim("rotate-me", "buyer@example.com", intake_thread())

      assert {:ok, rotated, new_token} = Slugs.rotate_confirmation_token(slug)

      assert rotated.confirmation_token_hash == Token.hash(new_token)
      refute new_token == old_token
      assert {:error, :invalid} = confirm_claim(old_token)
      assert {:ok, _} = confirm_claim(new_token)
    end

    test "refuses confirmed and expired claims" do
      {:ok, _slug, token} = Slugs.claim("done-deal", "buyer@example.com", intake_thread())
      {:ok, confirmed} = confirm_claim(token)

      assert {:error, :invalid} = Slugs.rotate_confirmation_token(confirmed)

      {:ok, stale, _token} = Slugs.claim("stale-deal", "buyer@example.com", intake_thread())
      stale = expire!(stale)

      assert {:error, :invalid} = Slugs.rotate_confirmation_token(stale)
    end
  end

  describe "release/1" do
    test "releases a claimed slug and re-opens it for claiming" do
      thread = intake_thread()
      {:ok, slug, _token} = Slugs.claim("give-back", "buyer@example.com", thread)

      assert {:ok, _released} = Slugs.release(admin_scope(), slug)
      refute Repo.get(Slug, slug.id)

      # The thread survives — only the slug row dies.
      assert Repo.get(Thread, thread.id)

      # Available again, claimable by anyone.
      assert available?("give-back")

      assert {:ok, _slug, _token} =
               Slugs.claim("give-back", "other@example.com", intake_thread())
    end

    test "releases a confirmed slug" do
      {:ok, _slug, token} = Slugs.claim("give-back-2", "buyer@example.com", intake_thread())
      {:ok, confirmed} = confirm_claim(token)

      assert {:ok, _released} = Slugs.release(admin_scope(), confirmed)
      assert available?("give-back-2")
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

      assert {:error, :provisioned} = Slugs.release(admin_scope(), provisioned)
      assert Repo.get(Slug, provisioned.id)
    end
  end

  describe "promote/2" do
    test "promotes a confirmed claim to provisioned, linking the organization" do
      thread = intake_thread()
      {:ok, _slug, token} = Slugs.claim("promote-me", "buyer@example.com", thread)
      {:ok, _confirmed} = confirm_claim(token)
      org = insert_organization()

      assert {:ok, :provisioned} = Slugs.promote(thread, org)
      promoted = Repo.get_by!(Slug, thread_id: thread.id)
      assert promoted.status == :provisioned
      assert promoted.organization_id == org.id
    end

    test "an unconfirmed (merely claimed) row is not promoted" do
      thread = intake_thread()
      {:ok, _slug, _token} = Slugs.claim("still-pending", "buyer@example.com", thread)
      org = insert_organization()

      assert {:error, :not_found} = Slugs.promote(thread, org)
      assert Repo.get_by!(Slug, thread_id: thread.id).status == :claimed
    end

    test "a thread with no claim at all is not a failure" do
      thread = intake_thread()
      org = insert_organization()

      assert {:error, :not_found} = Slugs.promote(thread, org)
    end

    test "an already-provisioned row is not re-promoted" do
      thread = intake_thread()
      {:ok, _slug, token} = Slugs.claim("once-only", "buyer@example.com", thread)
      {:ok, _confirmed} = confirm_claim(token)
      org = insert_organization()
      other_org = insert_organization()

      assert {:ok, _} = Slugs.promote(thread, org)
      assert {:error, :not_found} = Slugs.promote(thread, other_org)
      assert Repo.get_by!(Slug, thread_id: thread.id).organization_id == org.id
    end
  end

  describe "available?/1" do
    test "no row means available" do
      assert available?("never-claimed")
    end

    test "live and confirmed claims block; expired ones do not" do
      {:ok, _slug, token} = Slugs.claim("checking", "buyer@example.com", intake_thread())
      refute available?("checking")
      refute available?("  CHECKING  ")

      {:ok, _} = confirm_claim(token)
      refute available?("checking")

      {:ok, stale, _} = Slugs.claim("lapsing", "buyer@example.com", intake_thread())
      expire!(stale)
      assert available?("lapsing")
    end
  end

  describe "get_claim_for_thread/1" do
    test "returns the live claim and hides expired ones" do
      thread = intake_thread()
      assert is_nil(Slugs.get_claim_for_thread(thread.id))

      {:ok, slug, token} = Slugs.claim("my-live-claim", "buyer@example.com", thread)
      assert Slugs.get_claim_for_thread(thread.id).id == slug.id

      {:ok, _} = confirm_claim(token)
      assert Slugs.get_claim_for_thread(thread.id).status == :confirmed

      other = intake_thread()
      {:ok, stale, _} = Slugs.claim("other-claim", "other@example.com", other)
      expire!(stale)
      assert is_nil(Slugs.get_claim_for_thread(other.id))
    end
  end

  describe "expiry" do
    test "expiry releases the slug only; the thread and its messages persist" do
      thread = intake_thread()
      insert_message(thread_id: thread.id, source: :email, body: "still here")

      {:ok, slug, _token} = Slugs.claim("fleeting", "buyer@example.com", thread)
      expire!(slug)

      assert Slugs.delete_expired_claims() == 1
      refute Repo.get(Slug, slug.id)
      assert Repo.get(Thread, thread.id)

      assert Repo.aggregate(
               from(m in Custyard.Message, where: m.thread_id == ^thread.id),
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
                 "INSERT INTO slugs (tenant_id, slug, status, inserted_at, updated_at) " <>
                   "VALUES (#{Custyard.Factory.factory_tenant_id()}, 'bad-provisioned', 'provisioned', '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
               )

      assert message =~ "CHECK"
    end

    test "non-provisioned with an organization raises" do
      org = insert_organization()

      for status <- ["claimed", "confirmed"] do
        assert {:error, %Exqlite.Error{message: message}} =
                 Repo.query(
                   "INSERT INTO slugs (tenant_id, slug, status, organization_id, inserted_at, updated_at) " <>
                     "VALUES (#{Custyard.Factory.factory_tenant_id()}, 'bad-#{status}', '#{status}', #{org.id}, '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
                 )

        assert message =~ "CHECK"
      end
    end

    test "provisioned with an organization inserts (the CHECK passes both ways)" do
      org = insert_organization()

      assert {:ok, _} =
               Repo.query(
                 "INSERT INTO slugs (tenant_id, slug, status, organization_id, inserted_at, updated_at) " <>
                   "VALUES (#{Custyard.Factory.factory_tenant_id()}, 'good-provisioned', 'provisioned', #{org.id}, '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
               )
    end

    test "unknown status values raise on the status CHECK" do
      assert {:error, %Exqlite.Error{message: message}} =
               Repo.query(
                 "INSERT INTO slugs (tenant_id, slug, status, inserted_at, updated_at) " <>
                   "VALUES (#{Custyard.Factory.factory_tenant_id()}, 'bad-status', 'tombstoned', '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
               )

      assert message =~ "CHECK"
    end
  end

  describe "delete_expired_claims/1 and purged threads" do
    import Ecto.Query

    test "removes claimed and confirmed rows whose thread was purged" do
      claimed = intake_thread()
      {:ok, claimed_slug, _token} = Slugs.claim("orphan-claimed", "a@example.com", claimed)

      confirmed = intake_thread()
      {:ok, _slug, token} = Slugs.claim("orphan-confirmed", "b@example.com", confirmed)
      {:ok, confirmed_slug} = confirm_claim(token)

      # The retention purge nilifies slugs.thread_id (ON DELETE SET NULL)
      Custyard.Repo.update_all(
        from(s in Slug, where: s.id in ^[claimed_slug.id, confirmed_slug.id]),
        set: [thread_id: nil]
      )

      assert Slugs.delete_expired_claims() == 2
      assert available?("orphan-claimed")
      assert available?("orphan-confirmed")
    end

    test "keeps provisioned rows and live claims" do
      live = intake_thread()
      {:ok, _slug, _token} = Slugs.claim("still-live", "c@example.com", live)

      promoted = intake_thread()
      {:ok, promoted_slug, _token} = Slugs.claim("promoted-co", "d@example.com", promoted)
      org = insert_organization()

      # A provisioned row carries its organization (CHECK constraint).
      Custyard.Repo.update_all(
        from(s in Slug, where: s.id == ^promoted_slug.id),
        set: [status: :provisioned, organization_id: org.id, thread_id: nil]
      )

      assert Slugs.delete_expired_claims() == 0
      refute available?("still-live")
      refute available?("promoted-co")
    end
  end

  defp available?(text), do: Slugs.available?(text, Custyard.Factory.factory_tenant_id())

  defp admin_scope do
    staff = insert_staff_account(tenant_id: factory_tenant_id(), role: "admin")
    Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
  end

  defp confirm_claim(token), do: Slugs.confirm(token, factory_tenant_id())
  defp peek_claim(token), do: Slugs.peek(token, factory_tenant_id())

  test "claim credentials are tenant-bound and stop at suspension" do
    thread = intake_thread()
    {:ok, _claim, token} = Slugs.claim("tenant-bound-claim", "claimant@example.com", thread)
    other = insert_tenant()
    assert {:error, :invalid} = Slugs.peek(token, other.id)
    assert {:error, :invalid} = Slugs.confirm(token, other.id)
    assert {:ok, _} = Slugs.peek(token, thread.tenant_id)

    Custyard.Tenants.get_tenant!(thread.tenant_id)
    |> Ecto.Changeset.change(status: "suspended")
    |> Repo.update!()

    assert {:error, :invalid} = Slugs.peek(token, thread.tenant_id)
    assert {:error, :invalid} = Slugs.confirm(token, thread.tenant_id)
  end
end

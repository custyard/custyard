defmodule Custyard.IntakeTest do
  use Custyard.DataCase, async: true

  alias Custyard.{Contact, Thread, Intake, IntakeSource, Message, Organization, Prospect}
  alias Custyard.Auth.Token

  import Custyard.Factory

  describe "create_intake_thread/3" do
    setup do
      %{source: insert_intake_source(key: "landing-page")}
    end

    test "creates thread, prospect, and first message atomically", %{source: source} do
      assert {:ok, %{thread: thread, prospect: prospect, access_token: token}} =
               create_intake("landing-page", "Hello, I need help with X")

      assert thread.source == :public_intake
      assert thread.organization_id == nil
      assert thread.contact_id == nil
      assert thread.intake_source_key == source.key
      assert thread.state == :new
      assert thread.subject == "Hello, I need help with X"
      assert thread.last_customer_action_at != nil

      assert prospect.thread_id == thread.id

      [message] = Repo.all(from m in Message, where: m.thread_id == ^thread.id)
      assert message.source == :prospect
      assert message.origin == :public_intake
      assert message.body == "Hello, I need help with X"
      assert message.delivery_status == nil
      assert message.sender_email == nil
      refute message.is_internal_note

      assert is_binary(token)
    end

    test "stores only the token hash at rest, never the plaintext" do
      assert {:ok, %{prospect: prospect, access_token: token}} =
               create_intake("landing-page", "Hello")

      stored = Repo.get!(Prospect, prospect.id)
      assert stored.access_token_hash == Token.hash(token)
      refute stored.access_token_hash == token
      # The plaintext never appears in the prospects table
      assert Repo.get_by(Prospect, access_token_hash: token) == nil
    end

    test "caches a score greater than zero" do
      assert {:ok, %{thread: thread}} =
               create_intake("landing-page", "Hello")

      assert thread.cached_score > 0
    end

    test "broadcasts thread_created on the threads topic" do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      assert {:ok, %{thread: thread}} =
               create_intake("landing-page", "Hello")

      thread_id = thread.id
      assert_receive {:thread_created, ^thread_id}
    end

    test "derives the subject from the first non-empty line" do
      body = "\n\n   \nActual subject line\nsecond line with more detail"

      assert {:ok, %{thread: thread}} =
               create_intake("landing-page", body)

      assert thread.subject == "Actual subject line"
    end

    test "truncates the derived subject to 80 chars" do
      first_line = String.duplicate("s", 100)

      assert {:ok, %{thread: thread}} =
               create_intake("landing-page", first_line <> "\nrest")

      assert thread.subject == String.duplicate("s", 77) <> "..."
      assert String.length(thread.subject) == 80
    end

    test "truncates oversized bodies to the Normalizer limit" do
      body = String.duplicate("b", 100_001)

      assert {:ok, %{thread: thread}} =
               create_intake("landing-page", body)

      [message] = Repo.all(from m in Message, where: m.thread_id == ^thread.id)
      assert String.length(message.body) == 100_000
      assert String.ends_with?(message.body, "...")
    end

    test "rejects an empty body" do
      assert {:error, %Ecto.Changeset{}} = create_intake("landing-page", "")

      assert {:error, %Ecto.Changeset{}} =
               create_intake("landing-page", "\n  \n")

      assert Repo.aggregate(Thread, :count) == 0
      assert Repo.aggregate(Prospect, :count) == 0
    end

    test "rejects unknown source keys" do
      assert {:error, :unknown_source} = create_intake("nope", "Hello")
      assert Repo.aggregate(Thread, :count) == 0
    end

    test "rejects disabled source keys" do
      insert_intake_source(key: "paused", enabled: false)

      assert {:error, :unknown_source} = create_intake("paused", "Hello")
      assert Repo.aggregate(Thread, :count) == 0
    end
  end

  describe "get_thread_by_access_token/1" do
    setup do
      insert_intake_source(key: "cta")

      {:ok, %{thread: thread, access_token: token}} =
        create_intake("cta", "Hello from a prospect")

      %{thread: thread, token: token}
    end

    test "round-trips a valid token with thread-view preloads", %{
      thread: thread,
      token: token
    } do
      assert {:ok, loaded} = lookup_token(token)
      assert loaded.id == thread.id
      assert Ecto.assoc_loaded?(loaded.prospect)
      assert Ecto.assoc_loaded?(loaded.organization)
      assert Ecto.assoc_loaded?(loaded.contact)
      assert Ecto.assoc_loaded?(loaded.messages)
      assert [%Message{source: :prospect}] = loaded.messages
    end

    test "rejects unknown tokens" do
      assert {:error, :not_found} = lookup_token("bogus")
      assert {:error, :not_found} = lookup_token(nil)
    end

    test "rejects revoked tokens", %{thread: thread, token: token} do
      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)
      assert {:error, :not_found} = lookup_token(token)
    end

    test "excludes internal notes from the preloaded messages", %{
      thread: thread,
      token: token
    } do
      insert_message(
        thread_id: thread.id,
        source: :staff,
        is_internal_note: true,
        body: "secret staff note"
      )

      assert {:ok, loaded} = lookup_token(token)
      refute Enum.any?(loaded.messages, & &1.is_internal_note)
    end
  end

  describe "rotate_access_token/1" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = create_intake("cta", "Hello")
      %{thread: result.thread, token: result.access_token}
    end

    test "invalidates the old token and returns a new plaintext once", %{
      thread: thread,
      token: old_token
    } do
      assert {:ok, %{prospect: prospect, access_token: new_token}} =
               Intake.rotate_access_token(thread)

      refute new_token == old_token
      assert prospect.access_token_hash == Token.hash(new_token)

      assert {:error, :not_found} = lookup_token(old_token)
      assert {:ok, loaded} = lookup_token(new_token)
      assert loaded.id == thread.id
    end

    test "returns an error for threads without a prospect" do
      thread = insert_thread()
      assert {:error, :no_prospect} = Intake.rotate_access_token(thread)
    end

    test "rejects rotation after thread access is revoked", %{thread: thread} do
      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)
      assert {:error, :no_prospect} = Intake.rotate_access_token(thread)
    end

    test "broadcasts thread_access_changed on the thread topic", %{
      thread: thread
    } do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")

      assert {:ok, _result} = Intake.rotate_access_token(thread)

      thread_id = thread.id
      assert_receive {:thread_access_changed, ^thread_id}
    end
  end

  describe "access_token_valid?/1" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = create_intake("cta", "Hello")
      %{thread: result.thread, token: result.access_token}
    end

    test "true for a live token", %{token: token} do
      assert valid_token?(token)
    end

    test "false for unknown and non-binary tokens" do
      refute valid_token?("bogus")
      refute valid_token?(nil)
    end

    test "false once revoked", %{thread: thread, token: token} do
      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)
      refute valid_token?(token)
    end

    test "false for the old token after rotation", %{thread: thread, token: token} do
      assert {:ok, %{access_token: new_token}} = Intake.rotate_access_token(thread)

      refute valid_token?(token)
      assert valid_token?(new_token)
    end
  end

  describe "token rotation strips access from handles under the old token" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = create_intake("cta", "Hello")
      old_hash = Token.hash(result.access_token)

      {:ok, %{access_token: new_token}} = Intake.rotate_access_token(result.thread)

      %{
        thread: result.thread,
        old_hash: old_hash,
        new_hash: Token.hash(new_token)
      }
    end

    test "add_prospect_reply refuses a stale token hash", %{
      thread: thread,
      old_hash: old_hash,
      new_hash: new_hash
    } do
      assert {:error, :no_prospect} =
               Intake.add_prospect_reply(thread, "Still me?", token_hash: old_hash)

      assert Repo.aggregate(Message, :count) == 1

      assert {:ok, _result} =
               Intake.add_prospect_reply(thread, "Current bearer", token_hash: new_hash)
    end

    test "set_notification refuses a stale token hash", %{
      thread: thread,
      old_hash: old_hash,
      new_hash: new_hash
    } do
      assert {:error, :no_prospect} =
               Intake.set_notification(thread, true, token_hash: old_hash)

      assert {:ok, %Prospect{notify_on_reply: true}} =
               Intake.set_notification(thread, true, token_hash: new_hash)
    end

    test "capture_email refuses a stale hash without revealing capture state", %{
      thread: thread,
      old_hash: old_hash,
      new_hash: new_hash
    } do
      assert {:error, :no_prospect} =
               Intake.capture_email(thread, "a@example.com", token_hash: old_hash)

      assert {:ok, _thread} =
               Intake.capture_email(thread, "a@example.com", token_hash: new_hash)

      # Still :no_prospect, never :already_captured — a rotated-out handle
      # cannot learn that an email has since been captured.
      assert {:error, :no_prospect} =
               Intake.capture_email(thread, "b@example.com", token_hash: old_hash)
    end

    test "callers without a token hash are unaffected", %{thread: thread} do
      assert {:ok, _result} = Intake.add_prospect_reply(thread, "From the intake POST")
    end
  end

  describe "add_prospect_reply/3 revocation guard" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = create_intake("cta", "Hello")
      %{thread: result.thread}
    end

    test "refuses the write once thread access is revoked", %{thread: thread} do
      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)

      assert {:error, :no_prospect} = Intake.add_prospect_reply(thread, "Still here?")
      assert Repo.aggregate(Message, :count) == 1
    end
  end

  describe "add_prospect_reply/3 duplicate suppression" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = create_intake("cta", "Hello")
      %{thread: result.thread}
    end

    test "refuses a reply identical to the prospect's most recent message", %{
      thread: thread
    } do
      assert {:ok, _result} = Intake.add_prospect_reply(thread, "Any update?")

      assert {:error, :duplicate_message} = Intake.add_prospect_reply(thread, "Any update?")
      assert Repo.aggregate(Message, :count) == 2
    end

    test "the comparison trims both sides", %{thread: thread} do
      # The intake body itself is the prospect's most recent message.
      assert {:error, :duplicate_message} = Intake.add_prospect_reply(thread, "  Hello \n")
      assert Repo.aggregate(Message, :count) == 1
    end

    test "only the single most recent prospect message is compared", %{
      thread: thread
    } do
      assert {:ok, _result} = Intake.add_prospect_reply(thread, "First")
      assert {:ok, _result} = Intake.add_prospect_reply(thread, "Second")

      # "First" is older than the latest prospect message — resending it is fine.
      assert {:ok, _result} = Intake.add_prospect_reply(thread, "First")
    end

    test "an intervening staff message neither resets nor triggers the check", %{
      thread: thread
    } do
      assert {:ok, _result} = Intake.add_prospect_reply(thread, "Any update?")

      insert_message(
        thread_id: thread.id,
        source: :staff,
        body: "Staff body, never compared"
      )

      # The latest PROSPECT message is still "Any update?" even though the
      # staff spoke since — the duplicate stays refused.
      assert {:error, :duplicate_message} = Intake.add_prospect_reply(thread, "Any update?")

      # And a staff body is never a duplicate trigger.
      assert {:ok, _result} =
               Intake.add_prospect_reply(thread, "Staff body, never compared")
    end
  end

  describe "first_enabled_active_source/0" do
    test "returns the first enabled active-mode source ordered by key" do
      insert_intake_source(key: "zz-active", mode: :active)
      insert_intake_source(key: "aa-disabled", mode: :active, enabled: false)
      insert_intake_source(key: "bb-passive", mode: :passive)
      insert_intake_source(key: "mm-active", mode: :active)

      assert %IntakeSource{key: "mm-active"} =
               Intake.first_enabled_active_source(Custyard.Factory.factory_tenant_id())
    end

    test "returns nil when no enabled active source exists" do
      insert_intake_source(key: "only-passive", mode: :passive)
      insert_intake_source(key: "off", mode: :active, enabled: false)

      assert Intake.first_enabled_active_source(Custyard.Factory.factory_tenant_id()) == nil
    end
  end

  describe "set_notification/3" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = create_intake("cta", "Hello")
      %{thread: result.thread}
    end

    test "toggles the notification preference", %{thread: thread} do
      assert {:ok, %Prospect{notify_on_reply: true}} =
               Intake.set_notification(thread, true)

      assert {:ok, %Prospect{notify_on_reply: false}} =
               Intake.set_notification(thread, false)
    end

    test "returns an error for threads without a prospect" do
      thread = insert_thread()
      assert {:error, :no_prospect} = Intake.set_notification(thread, true)
    end

    test "rejects the toggle after thread access is revoked", %{thread: thread} do
      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)

      assert {:error, :no_prospect} = Intake.set_notification(thread, true)

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.notify_on_reply == false
    end
  end

  describe "capture_email/3" do
    setup do
      thread = insert_thread(source: :public_intake, intake_source_key: "cta")
      insert_prospect(thread_id: thread.id)
      Custyard.Scoring.calculate_and_cache(thread.id)
      %{thread: Repo.reload!(thread)}
    end

    test "contact match sets both FKs in one write, rescores, and broadcasts to the org topic",
         %{thread: thread} do
      org = insert_organization(tier: :enterprise, domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      score_before = thread.cached_score

      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:#{org.id}")

      assert {:ok, updated} = Intake.capture_email(thread, "alice@acme.example.com")

      assert updated.organization_id == org.id
      assert updated.contact_id == contact.id

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == "alice@acme.example.com"
      assert prospect.email_captured_at != nil

      # Enterprise tier (20) outscores the unlinked default (10)
      assert updated.cached_score > score_before

      thread_id = thread.id
      # One message per subscribed topic
      assert_receive {:thread_updated, ^thread_id}
      assert_receive {:thread_updated, ^thread_id}
      assert_receive {:thread_updated, ^thread_id}
    end

    test "domain match links the organization only", %{thread: thread} do
      org = insert_organization(domain: "widgets.example.com")
      contact_count = Repo.aggregate(Contact, :count)

      assert {:ok, updated} = Intake.capture_email(thread, "new@widgets.example.com")

      assert updated.organization_id == org.id
      assert updated.contact_id == nil
      # Lookup-only resolution: no contact is created
      assert Repo.aggregate(Contact, :count) == contact_count
    end

    test "no match records the email and creates nothing", %{thread: thread} do
      org_count = Repo.aggregate(Organization, :count)
      contact_count = Repo.aggregate(Contact, :count)

      assert {:ok, updated} = Intake.capture_email(thread, "stranger@unknown.example.net")

      assert updated.organization_id == nil
      assert updated.contact_id == nil
      assert Repo.aggregate(Organization, :count) == org_count
      assert Repo.aggregate(Contact, :count) == contact_count

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == "stranger@unknown.example.net"
    end

    test "no match never publishes the malformed org topic", %{thread: thread} do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:")

      assert {:ok, _updated} = Intake.capture_email(thread, "stranger@unknown.example.net")

      refute_receive {:thread_updated, _}, 50
    end

    test "capture is write-once", %{thread: thread} do
      assert {:ok, _} = Intake.capture_email(thread, "first@example.com")

      assert {:error, :already_captured} =
               Intake.capture_email(thread, "second@example.com")

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == "first@example.com"
    end

    test "rejects capture after thread access is revoked", %{thread: thread} do
      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)

      # Same error as a missing prospect: revoked and absent are
      # indistinguishable to the caller.
      assert {:error, :no_prospect} = Intake.capture_email(thread, "late@example.com")

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == nil
      assert prospect.notify_on_reply == false
    end

    test "never overwrites an existing organization link" do
      linked_org = insert_organization(domain: "linked.example.com")
      other_org = insert_organization(domain: "acme.example.com")
      insert_contact(organization_id: other_org.id, email: "alice@acme.example.com")

      thread =
        insert_thread(
          source: :public_intake,
          intake_source_key: "cta",
          organization_id: linked_org.id
        )

      insert_prospect(thread_id: thread.id)

      assert {:ok, updated} = Intake.capture_email(thread, "alice@acme.example.com")

      # Staff linkage wins over capture-time resolution; the email is
      # still captured on the prospect.
      assert updated.organization_id == linked_org.id
      assert updated.contact_id == nil

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == "alice@acme.example.com"
    end

    test "a stale nil-org struct cannot clobber a link written after mount", %{
      thread: thread
    } do
      # Organization A: the thread gets linked to this in the DB after
      # the in-memory struct was loaded (e.g. a staff ran
      # convert_prospect/3 against a socket still holding organization_id: nil).
      org_a = insert_organization(domain: "already.example.com")

      # Organization B: what capture-time email resolution would resolve to.
      org_b = insert_organization(domain: "acme.example.com")
      insert_contact(organization_id: org_b.id, email: "alice@acme.example.com")

      # DB row now points at A while our `thread` struct is stale (nil org).
      Repo.get!(Thread, thread.id)
      |> Ecto.Changeset.change(organization_id: org_a.id)
      |> Repo.update!()

      assert thread.organization_id == nil

      assert {:ok, _updated} = Intake.capture_email(thread, "alice@acme.example.com")

      # The stale write lost the DB-side race (WHERE organization_id IS NULL):
      # the row still links to A and B never clobbered it.
      reloaded = Repo.get!(Thread, thread.id)
      assert reloaded.organization_id == org_a.id
      assert reloaded.contact_id == nil

      # The email is still captured even though the link was skipped.
      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == "alice@acme.example.com"
    end

    test "downcases and trims before resolving and storing", %{thread: thread} do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, updated} = Intake.capture_email(thread, "  ALICE@Acme.Example.COM ")

      assert updated.contact_id == contact.id
      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == "alice@acme.example.com"
    end

    test "returns the same success shape regardless of link outcome", %{
      thread: thread
    } do
      org = insert_organization(domain: "acme.example.com")
      insert_contact(organization_id: org.id, email: "known@acme.example.com")

      results = [
        Intake.capture_email(thread, "known@acme.example.com"),
        capture_on_fresh_intake_thread("other@acme.example.com"),
        capture_on_fresh_intake_thread("nobody@unknown.example.net")
      ]

      for result <- results do
        assert {:ok, %Thread{}} = result
      end
    end

    test "notify option stores consent alongside the email", %{thread: thread} do
      assert {:ok, _} = Intake.capture_email(thread, "a@example.com", notify: true)

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.notify_on_reply == true
    end

    test "rejects invalid emails without storing anything", %{thread: thread} do
      assert {:error, %Ecto.Changeset{}} = Intake.capture_email(thread, "not-an-email")

      prospect = Repo.get_by!(Prospect, thread_id: thread.id)
      assert prospect.email == nil
    end

    test "returns an error for threads without a prospect" do
      thread = insert_thread()
      assert {:error, :no_prospect} = Intake.capture_email(thread, "a@example.com")
    end

    defp capture_on_fresh_intake_thread(email) do
      thread = insert_thread(source: :public_intake)
      insert_prospect(thread_id: thread.id)
      Intake.capture_email(thread, email)
    end
  end

  describe "intake source CRUD" do
    test "list_sources/0 returns sources ordered by key" do
      insert_intake_source(key: "zeta")
      insert_intake_source(key: "alpha")

      assert ["alpha", "zeta"] = Intake.list_sources(source_scope()) |> Enum.map(& &1.key)
    end

    test "get_enabled_source/1 returns nil for unknown, disabled, or non-binary keys" do
      source = insert_intake_source(key: "live")
      insert_intake_source(key: "paused", enabled: false)

      assert %IntakeSource{id: id} = get_enabled_source("live")
      assert id == source.id
      assert get_enabled_source("paused") == nil
      assert get_enabled_source("missing") == nil
      assert get_enabled_source(nil) == nil
      assert get_enabled_source(:live) == nil
    end

    test "create_source/1 validates attributes" do
      assert {:ok, %IntakeSource{key: "docs-cta"}} =
               Intake.create_source(source_scope(), %{
                 tenant_id: Custyard.Factory.factory_tenant_id(),
                 key: "docs-cta",
                 name: "Docs CTA"
               })

      assert {:error, %Ecto.Changeset{}} =
               Intake.create_source(source_scope(), %{
                 tenant_id: Custyard.Factory.factory_tenant_id(),
                 key: "Bad Key!",
                 name: "Nope"
               })
    end

    test "update_source/2 applies changes" do
      source = insert_intake_source()

      assert {:ok, updated} =
               Intake.update_source(source_scope(), source, %{name: "Renamed", mode: :passive})

      assert updated.name == "Renamed"
      assert updated.mode == :passive
    end

    test "update_source/2 never changes the key (immutable public URL segment)" do
      source = insert_intake_source(key: "original")

      assert {:ok, updated} =
               Intake.update_source(source_scope(), source, %{key: "other", name: "Renamed"})

      assert updated.key == "original"
      assert updated.name == "Renamed"

      # String keys (the LiveView param shape) are ignored the same way.
      assert {:ok, updated} = Intake.update_source(source_scope(), source, %{"key" => "other"})
      assert updated.key == "original"
      assert Repo.reload!(source).key == "original"
    end

    test "delete_source/1 removes the source but leaves thread provenance" do
      source = insert_intake_source(key: "ephemeral")

      thread =
        insert_thread(source: :public_intake, intake_source_key: "ephemeral")

      assert {:ok, _} = Intake.delete_source(source_scope(), source)
      assert Repo.reload!(thread).intake_source_key == "ephemeral"
    end
  end

  describe "revoke_thread_access/1 and slug claims" do
    test "revoking access releases the thread's pending claim" do
      source = insert_intake_source(mode: :active)
      {:ok, %{thread: thread}} = create_intake(source.key, "Hi")

      {:ok, _slug, confirmation_token} =
        Custyard.Slugs.claim("revoked-co", "x@example.com", thread)

      assert {:ok, _prospect} = Intake.revoke_thread_access(thread)

      assert is_nil(Custyard.Slugs.get_claim_for_thread(thread.id))
      # The link already in the abuser's inbox no longer confirms anything
      assert {:error, :invalid} =
               Custyard.Slugs.confirm(confirmation_token, Custyard.Factory.factory_tenant_id())

      assert Custyard.Slugs.available?("revoked-co", Custyard.Factory.factory_tenant_id())
    end
  end

  defp create_intake(key, body, opts \\ []),
    do:
      Intake.create_intake_thread(
        key,
        body,
        Keyword.put(opts, :tenant_id, Custyard.Factory.factory_tenant_id())
      )

  defp get_enabled_source(key),
    do: Intake.get_enabled_source(key, Custyard.Factory.factory_tenant_id())

  defp source_scope do
    staff = insert_staff_account(tenant_id: factory_tenant_id(), role: "admin")
    Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
  end

  defp lookup_token(token),
    do: Intake.get_thread_by_access_token(token, factory_tenant_id())

  defp valid_token?(token), do: Intake.access_token_valid?(token, factory_tenant_id())
end

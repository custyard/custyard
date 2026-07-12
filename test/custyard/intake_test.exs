defmodule Custyard.IntakeTest do
  use Custyard.DataCase, async: true

  alias Custyard.{Contact, Conversation, Intake, IntakeSource, Message, Organization, Prospect}
  alias Custyard.Auth.Token

  import Custyard.Factory

  describe "create_intake_conversation/3" do
    setup do
      %{source: insert_intake_source(key: "landing-page")}
    end

    test "creates conversation, prospect, and first message atomically", %{source: source} do
      assert {:ok, %{conversation: conversation, prospect: prospect, resume_token: token}} =
               Intake.create_intake_conversation("landing-page", "Hello, I need help with X")

      assert conversation.source == :public_intake
      assert conversation.organization_id == nil
      assert conversation.contact_id == nil
      assert conversation.intake_source_key == source.key
      assert conversation.state == :new
      assert conversation.subject == "Hello, I need help with X"
      assert conversation.last_customer_action_at != nil

      assert prospect.conversation_id == conversation.id

      [message] = Repo.all(from m in Message, where: m.conversation_id == ^conversation.id)
      assert message.source == :prospect
      assert message.origin == :public_intake
      assert message.body == "Hello, I need help with X"
      assert message.delivery_status == nil
      assert message.sender_email == nil
      refute message.is_internal_note

      assert is_binary(token)
    end

    test "stores only the token hash at rest, never the plaintext" do
      assert {:ok, %{prospect: prospect, resume_token: token}} =
               Intake.create_intake_conversation("landing-page", "Hello")

      stored = Repo.get!(Prospect, prospect.id)
      assert stored.resume_token_hash == Token.hash(token)
      refute stored.resume_token_hash == token
      # The plaintext never appears in the prospects table
      assert Repo.get_by(Prospect, resume_token_hash: token) == nil
    end

    test "caches a score greater than zero" do
      assert {:ok, %{conversation: conversation}} =
               Intake.create_intake_conversation("landing-page", "Hello")

      assert conversation.cached_score > 0
    end

    test "broadcasts conversation_created on the conversations topic" do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")

      assert {:ok, %{conversation: conversation}} =
               Intake.create_intake_conversation("landing-page", "Hello")

      conversation_id = conversation.id
      assert_receive {:conversation_created, ^conversation_id}
    end

    test "derives the subject from the first non-empty line" do
      body = "\n\n   \nActual subject line\nsecond line with more detail"

      assert {:ok, %{conversation: conversation}} =
               Intake.create_intake_conversation("landing-page", body)

      assert conversation.subject == "Actual subject line"
    end

    test "truncates the derived subject to 80 chars" do
      first_line = String.duplicate("s", 100)

      assert {:ok, %{conversation: conversation}} =
               Intake.create_intake_conversation("landing-page", first_line <> "\nrest")

      assert conversation.subject == String.duplicate("s", 77) <> "..."
      assert String.length(conversation.subject) == 80
    end

    test "truncates oversized bodies to the Normalizer limit" do
      body = String.duplicate("b", 100_001)

      assert {:ok, %{conversation: conversation}} =
               Intake.create_intake_conversation("landing-page", body)

      [message] = Repo.all(from m in Message, where: m.conversation_id == ^conversation.id)
      assert String.length(message.body) == 100_000
      assert String.ends_with?(message.body, "...")
    end

    test "rejects an empty body" do
      assert {:error, %Ecto.Changeset{}} = Intake.create_intake_conversation("landing-page", "")

      assert {:error, %Ecto.Changeset{}} =
               Intake.create_intake_conversation("landing-page", "\n  \n")

      assert Repo.aggregate(Conversation, :count) == 0
      assert Repo.aggregate(Prospect, :count) == 0
    end

    test "rejects unknown source keys" do
      assert {:error, :unknown_source} = Intake.create_intake_conversation("nope", "Hello")
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "rejects disabled source keys" do
      insert_intake_source(key: "paused", enabled: false)

      assert {:error, :unknown_source} = Intake.create_intake_conversation("paused", "Hello")
      assert Repo.aggregate(Conversation, :count) == 0
    end
  end

  describe "get_conversation_by_resume_token/1" do
    setup do
      insert_intake_source(key: "cta")

      {:ok, %{conversation: conversation, resume_token: token}} =
        Intake.create_intake_conversation("cta", "Hello from a prospect")

      %{conversation: conversation, token: token}
    end

    test "round-trips a valid token with resume-view preloads", %{
      conversation: conversation,
      token: token
    } do
      assert {:ok, loaded} = Intake.get_conversation_by_resume_token(token)
      assert loaded.id == conversation.id
      assert Ecto.assoc_loaded?(loaded.prospect)
      assert Ecto.assoc_loaded?(loaded.organization)
      assert Ecto.assoc_loaded?(loaded.contact)
      assert Ecto.assoc_loaded?(loaded.messages)
      assert [%Message{source: :prospect}] = loaded.messages
    end

    test "rejects unknown tokens" do
      assert {:error, :not_found} = Intake.get_conversation_by_resume_token("bogus")
      assert {:error, :not_found} = Intake.get_conversation_by_resume_token(nil)
    end

    test "rejects revoked tokens", %{conversation: conversation, token: token} do
      assert {:ok, _prospect} = Intake.revoke_resume_access(conversation)
      assert {:error, :not_found} = Intake.get_conversation_by_resume_token(token)
    end

    test "excludes internal notes from the preloaded messages", %{
      conversation: conversation,
      token: token
    } do
      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        is_internal_note: true,
        body: "secret operator note"
      )

      assert {:ok, loaded} = Intake.get_conversation_by_resume_token(token)
      refute Enum.any?(loaded.messages, & &1.is_internal_note)
    end
  end

  describe "rotate_resume_token/1" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = Intake.create_intake_conversation("cta", "Hello")
      %{conversation: result.conversation, token: result.resume_token}
    end

    test "invalidates the old token and returns a new plaintext once", %{
      conversation: conversation,
      token: old_token
    } do
      assert {:ok, %{prospect: prospect, resume_token: new_token}} =
               Intake.rotate_resume_token(conversation)

      refute new_token == old_token
      assert prospect.resume_token_hash == Token.hash(new_token)

      assert {:error, :not_found} = Intake.get_conversation_by_resume_token(old_token)
      assert {:ok, loaded} = Intake.get_conversation_by_resume_token(new_token)
      assert loaded.id == conversation.id
    end

    test "returns an error for conversations without a prospect" do
      conversation = insert_conversation()
      assert {:error, :no_prospect} = Intake.rotate_resume_token(conversation)
    end

    test "rejects rotation after resume access is revoked", %{conversation: conversation} do
      assert {:ok, _prospect} = Intake.revoke_resume_access(conversation)
      assert {:error, :no_prospect} = Intake.rotate_resume_token(conversation)
    end

    test "broadcasts resume_access_changed on the conversation topic", %{
      conversation: conversation
    } do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conversation.id}")

      assert {:ok, _result} = Intake.rotate_resume_token(conversation)

      conversation_id = conversation.id
      assert_receive {:resume_access_changed, ^conversation_id}
    end
  end

  describe "resume_token_valid?/1" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = Intake.create_intake_conversation("cta", "Hello")
      %{conversation: result.conversation, token: result.resume_token}
    end

    test "true for a live token", %{token: token} do
      assert Intake.resume_token_valid?(token)
    end

    test "false for unknown and non-binary tokens" do
      refute Intake.resume_token_valid?("bogus")
      refute Intake.resume_token_valid?(nil)
    end

    test "false once revoked", %{conversation: conversation, token: token} do
      assert {:ok, _prospect} = Intake.revoke_resume_access(conversation)
      refute Intake.resume_token_valid?(token)
    end

    test "false for the old token after rotation", %{conversation: conversation, token: token} do
      assert {:ok, %{resume_token: new_token}} = Intake.rotate_resume_token(conversation)

      refute Intake.resume_token_valid?(token)
      assert Intake.resume_token_valid?(new_token)
    end
  end

  describe "token rotation strips access from handles under the old token" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = Intake.create_intake_conversation("cta", "Hello")
      old_hash = Token.hash(result.resume_token)

      {:ok, %{resume_token: new_token}} = Intake.rotate_resume_token(result.conversation)

      %{
        conversation: result.conversation,
        old_hash: old_hash,
        new_hash: Token.hash(new_token)
      }
    end

    test "add_prospect_reply refuses a stale token hash", %{
      conversation: conversation,
      old_hash: old_hash,
      new_hash: new_hash
    } do
      assert {:error, :no_prospect} =
               Intake.add_prospect_reply(conversation, "Still me?", token_hash: old_hash)

      assert Repo.aggregate(Message, :count) == 1

      assert {:ok, _result} =
               Intake.add_prospect_reply(conversation, "Current bearer", token_hash: new_hash)
    end

    test "set_notification refuses a stale token hash", %{
      conversation: conversation,
      old_hash: old_hash,
      new_hash: new_hash
    } do
      assert {:error, :no_prospect} =
               Intake.set_notification(conversation, true, token_hash: old_hash)

      assert {:ok, %Prospect{notify_on_reply: true}} =
               Intake.set_notification(conversation, true, token_hash: new_hash)
    end

    test "capture_email refuses a stale hash without revealing capture state", %{
      conversation: conversation,
      old_hash: old_hash,
      new_hash: new_hash
    } do
      assert {:error, :no_prospect} =
               Intake.capture_email(conversation, "a@example.com", token_hash: old_hash)

      assert {:ok, _conversation} =
               Intake.capture_email(conversation, "a@example.com", token_hash: new_hash)

      # Still :no_prospect, never :already_captured — a rotated-out handle
      # cannot learn that an email has since been captured.
      assert {:error, :no_prospect} =
               Intake.capture_email(conversation, "b@example.com", token_hash: old_hash)
    end

    test "callers without a token hash are unaffected", %{conversation: conversation} do
      assert {:ok, _result} = Intake.add_prospect_reply(conversation, "From the intake POST")
    end
  end

  describe "add_prospect_reply/3 revocation guard" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = Intake.create_intake_conversation("cta", "Hello")
      %{conversation: result.conversation}
    end

    test "refuses the write once resume access is revoked", %{conversation: conversation} do
      assert {:ok, _prospect} = Intake.revoke_resume_access(conversation)

      assert {:error, :no_prospect} = Intake.add_prospect_reply(conversation, "Still here?")
      assert Repo.aggregate(Message, :count) == 1
    end
  end

  describe "first_enabled_active_source/0" do
    test "returns the first enabled active-mode source ordered by key" do
      insert_intake_source(key: "zz-active", mode: :active)
      insert_intake_source(key: "aa-disabled", mode: :active, enabled: false)
      insert_intake_source(key: "bb-passive", mode: :passive)
      insert_intake_source(key: "mm-active", mode: :active)

      assert %IntakeSource{key: "mm-active"} = Intake.first_enabled_active_source()
    end

    test "returns nil when no enabled active source exists" do
      insert_intake_source(key: "only-passive", mode: :passive)
      insert_intake_source(key: "off", mode: :active, enabled: false)

      assert Intake.first_enabled_active_source() == nil
    end
  end

  describe "set_notification/3" do
    setup do
      insert_intake_source(key: "cta")
      {:ok, result} = Intake.create_intake_conversation("cta", "Hello")
      %{conversation: result.conversation}
    end

    test "toggles the notification preference", %{conversation: conversation} do
      assert {:ok, %Prospect{notify_on_reply: true}} =
               Intake.set_notification(conversation, true)

      assert {:ok, %Prospect{notify_on_reply: false}} =
               Intake.set_notification(conversation, false)
    end

    test "returns an error for conversations without a prospect" do
      conversation = insert_conversation()
      assert {:error, :no_prospect} = Intake.set_notification(conversation, true)
    end

    test "rejects the toggle after resume access is revoked", %{conversation: conversation} do
      assert {:ok, _prospect} = Intake.revoke_resume_access(conversation)

      assert {:error, :no_prospect} = Intake.set_notification(conversation, true)

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.notify_on_reply == false
    end
  end

  describe "capture_email/3" do
    setup do
      conversation = insert_conversation(source: :public_intake, intake_source_key: "cta")
      insert_prospect(conversation_id: conversation.id)
      Custyard.Scoring.calculate_and_cache(conversation.id)
      %{conversation: Repo.reload!(conversation)}
    end

    test "contact match sets both FKs in one write, rescores, and broadcasts to the org topic",
         %{conversation: conversation} do
      org = insert_organization(tier: :enterprise, domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      score_before = conversation.cached_score

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conversation.id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:#{org.id}")

      assert {:ok, updated} = Intake.capture_email(conversation, "alice@acme.example.com")

      assert updated.organization_id == org.id
      assert updated.contact_id == contact.id

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "alice@acme.example.com"
      assert prospect.email_captured_at != nil

      # Enterprise tier (20) outscores the unlinked default (10)
      assert updated.cached_score > score_before

      conversation_id = conversation.id
      # One message per subscribed topic
      assert_receive {:conversation_updated, ^conversation_id}
      assert_receive {:conversation_updated, ^conversation_id}
      assert_receive {:conversation_updated, ^conversation_id}
    end

    test "domain match links the organization only", %{conversation: conversation} do
      org = insert_organization(domain: "widgets.example.com")
      contact_count = Repo.aggregate(Contact, :count)

      assert {:ok, updated} = Intake.capture_email(conversation, "new@widgets.example.com")

      assert updated.organization_id == org.id
      assert updated.contact_id == nil
      # Lookup-only resolution: no contact is created
      assert Repo.aggregate(Contact, :count) == contact_count
    end

    test "no match records the email and creates nothing", %{conversation: conversation} do
      org_count = Repo.aggregate(Organization, :count)
      contact_count = Repo.aggregate(Contact, :count)

      assert {:ok, updated} = Intake.capture_email(conversation, "stranger@unknown.example.net")

      assert updated.organization_id == nil
      assert updated.contact_id == nil
      assert Repo.aggregate(Organization, :count) == org_count
      assert Repo.aggregate(Contact, :count) == contact_count

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "stranger@unknown.example.net"
    end

    test "no match never publishes the malformed org topic", %{conversation: conversation} do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:")

      assert {:ok, _updated} = Intake.capture_email(conversation, "stranger@unknown.example.net")

      refute_receive {:conversation_updated, _}, 50
    end

    test "capture is write-once", %{conversation: conversation} do
      assert {:ok, _} = Intake.capture_email(conversation, "first@example.com")

      assert {:error, :already_captured} =
               Intake.capture_email(conversation, "second@example.com")

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "first@example.com"
    end

    test "rejects capture after resume access is revoked", %{conversation: conversation} do
      assert {:ok, _prospect} = Intake.revoke_resume_access(conversation)

      # Same error as a missing prospect: revoked and absent are
      # indistinguishable to the caller.
      assert {:error, :no_prospect} = Intake.capture_email(conversation, "late@example.com")

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == nil
      assert prospect.notify_on_reply == false
    end

    test "never overwrites an existing organization link" do
      linked_org = insert_organization(domain: "linked.example.com")
      other_org = insert_organization(domain: "acme.example.com")
      insert_contact(organization_id: other_org.id, email: "alice@acme.example.com")

      conversation =
        insert_conversation(
          source: :public_intake,
          intake_source_key: "cta",
          organization_id: linked_org.id
        )

      insert_prospect(conversation_id: conversation.id)

      assert {:ok, updated} = Intake.capture_email(conversation, "alice@acme.example.com")

      # Operator linkage wins over capture-time resolution; the email is
      # still captured on the prospect.
      assert updated.organization_id == linked_org.id
      assert updated.contact_id == nil

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "alice@acme.example.com"
    end

    test "a stale nil-org struct cannot clobber a link written after mount", %{
      conversation: conversation
    } do
      # Organization A: the conversation gets linked to this in the DB after
      # the in-memory struct was loaded (e.g. an operator ran
      # convert_prospect/3 against a socket still holding organization_id: nil).
      org_a = insert_organization(domain: "already.example.com")

      # Organization B: what capture-time email resolution would resolve to.
      org_b = insert_organization(domain: "acme.example.com")
      insert_contact(organization_id: org_b.id, email: "alice@acme.example.com")

      # DB row now points at A while our `conversation` struct is stale (nil org).
      Repo.get!(Conversation, conversation.id)
      |> Ecto.Changeset.change(organization_id: org_a.id)
      |> Repo.update!()

      assert conversation.organization_id == nil

      assert {:ok, _updated} = Intake.capture_email(conversation, "alice@acme.example.com")

      # The stale write lost the DB-side race (WHERE organization_id IS NULL):
      # the row still links to A and B never clobbered it.
      reloaded = Repo.get!(Conversation, conversation.id)
      assert reloaded.organization_id == org_a.id
      assert reloaded.contact_id == nil

      # The email is still captured even though the link was skipped.
      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "alice@acme.example.com"
    end

    test "downcases and trims before resolving and storing", %{conversation: conversation} do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, updated} = Intake.capture_email(conversation, "  ALICE@Acme.Example.COM ")

      assert updated.contact_id == contact.id
      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == "alice@acme.example.com"
    end

    test "returns the same success shape regardless of link outcome", %{
      conversation: conversation
    } do
      org = insert_organization(domain: "acme.example.com")
      insert_contact(organization_id: org.id, email: "known@acme.example.com")

      results = [
        Intake.capture_email(conversation, "known@acme.example.com"),
        capture_on_fresh_intake_conversation("other@acme.example.com"),
        capture_on_fresh_intake_conversation("nobody@unknown.example.net")
      ]

      for result <- results do
        assert {:ok, %Conversation{}} = result
      end
    end

    test "notify option stores consent alongside the email", %{conversation: conversation} do
      assert {:ok, _} = Intake.capture_email(conversation, "a@example.com", notify: true)

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.notify_on_reply == true
    end

    test "rejects invalid emails without storing anything", %{conversation: conversation} do
      assert {:error, %Ecto.Changeset{}} = Intake.capture_email(conversation, "not-an-email")

      prospect = Repo.get_by!(Prospect, conversation_id: conversation.id)
      assert prospect.email == nil
    end

    test "returns an error for conversations without a prospect" do
      conversation = insert_conversation()
      assert {:error, :no_prospect} = Intake.capture_email(conversation, "a@example.com")
    end

    defp capture_on_fresh_intake_conversation(email) do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)
      Intake.capture_email(conversation, email)
    end
  end

  describe "intake source CRUD" do
    test "list_sources/0 returns sources ordered by key" do
      insert_intake_source(key: "zeta")
      insert_intake_source(key: "alpha")

      assert ["alpha", "zeta"] = Intake.list_sources() |> Enum.map(& &1.key)
    end

    test "get_enabled_source/1 returns nil for unknown, disabled, or non-binary keys" do
      source = insert_intake_source(key: "live")
      insert_intake_source(key: "paused", enabled: false)

      assert %IntakeSource{id: id} = Intake.get_enabled_source("live")
      assert id == source.id
      assert Intake.get_enabled_source("paused") == nil
      assert Intake.get_enabled_source("missing") == nil
      assert Intake.get_enabled_source(nil) == nil
      assert Intake.get_enabled_source(:live) == nil
    end

    test "create_source/1 validates attributes" do
      assert {:ok, %IntakeSource{key: "docs-cta"}} =
               Intake.create_source(%{key: "docs-cta", name: "Docs CTA"})

      assert {:error, %Ecto.Changeset{}} =
               Intake.create_source(%{key: "Bad Key!", name: "Nope"})
    end

    test "update_source/2 applies changes" do
      source = insert_intake_source()

      assert {:ok, updated} = Intake.update_source(source, %{name: "Renamed", mode: :passive})
      assert updated.name == "Renamed"
      assert updated.mode == :passive
    end

    test "update_source/2 never changes the key (immutable public URL segment)" do
      source = insert_intake_source(key: "original")

      assert {:ok, updated} = Intake.update_source(source, %{key: "other", name: "Renamed"})
      assert updated.key == "original"
      assert updated.name == "Renamed"

      # String keys (the LiveView param shape) are ignored the same way.
      assert {:ok, updated} = Intake.update_source(source, %{"key" => "other"})
      assert updated.key == "original"
      assert Repo.reload!(source).key == "original"
    end

    test "delete_source/1 removes the source but leaves conversation provenance" do
      source = insert_intake_source(key: "ephemeral")

      conversation =
        insert_conversation(source: :public_intake, intake_source_key: "ephemeral")

      assert {:ok, _} = Intake.delete_source(source)
      assert Repo.reload!(conversation).intake_source_key == "ephemeral"
    end
  end
end

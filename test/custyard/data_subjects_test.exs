defmodule Custyard.DataSubjectsTest do
  @moduledoc "DSAR coverage for CC participants (spec-inbound-channels, Privacy)."
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Email.{Outbound, SenderMatcher}

  alias Custyard.{AuditEvent, Contact, Thread, DataSubjects, Message, Repo}
  alias Custyard.{InboundChannelRejection, MessageAttachment, MessageRecipientStatus}
  alias Custyard.{Attachments, Files}
  alias Custyard.Files.StoredFile

  defp scope(org) do
    key = {:dsar_scope, org.tenant_id}

    case Process.get(key) do
      nil ->
        staff = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
        scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))
        Process.put(key, scope)
        scope

      scope ->
        scope
    end
  end

  setup do
    org = insert_organization()
    other_org = insert_organization()
    conv = insert_thread(organization_id: org.id, subject: "Invoice")
    other_conv = insert_thread(organization_id: other_org.id)

    sent =
      insert_message(
        thread_id: conv.id,
        sender_email: "Pat <pat@example.com>",
        to_addresses: ["help@acme.example"],
        body: "I wrote this"
      )

    cc =
      insert_message(
        thread_id: conv.id,
        sender_email: "alice@customer.example",
        to_addresses: ["help@acme.example"],
        cc_addresses: ["PAT@example.com", "boss@customer.example"],
        body: "Alice wrote this"
      )

    reply_to =
      insert_message(
        thread_id: conv.id,
        sender_email: "alice@customer.example",
        to_addresses: ["pat@example.com", "help@acme.example"],
        reply_to: "pat@example.com",
        body: "Alice again"
      )

    unrelated = insert_message(thread_id: conv.id, sender_email: "zed@example.com")
    foreign = insert_message(thread_id: other_conv.id, cc_addresses: ["pat@example.com"])

    %{org: org, sent: sent, cc: cc, reply_to: reply_to, unrelated: unrelated, foreign: foreign}
  end

  test "a foreign tenant scope cannot export or erase customer data", ctx do
    foreign = insert_tenant()
    staff = insert_staff_account(role: "admin", tenant_id: foreign.id)
    scope = Custyard.Scope.for_staff(staff, foreign)

    assert_raise Ecto.NoResultsError, fn ->
      DataSubjects.export(scope, "pat@example.com", ctx.org.id)
    end

    assert_raise Ecto.NoResultsError, fn ->
      DataSubjects.erase_subject(scope, "pat@example.com", ctx.org.id)
    end

    assert Repo.get(Custyard.Message, ctx.sent.id).body == "I wrote this"
  end

  test "erasure removes private drafts without affecting other customers", ctx do
    current_scope = scope(ctx.org)

    {:ok, draft} =
      Custyard.MessageDrafts.save(
        current_scope,
        ctx.sent.thread_id,
        %{reply_text: "Unsaved quote", reply_cc: "pat@example.com"},
        0
      )

    {:ok, other} =
      Custyard.MessageDrafts.save(
        current_scope,
        ctx.foreign.thread_id,
        %{note_text: "Other customer"},
        0
      )

    assert {:ok, _} = DataSubjects.erase_subject(current_scope, "pat@example.com", ctx.org.id)
    refute Repo.get(Custyard.StaffMessageDraft, draft.id)
    assert Repo.get(Custyard.StaffMessageDraft, other.id)

    assert {:error, :draft_conflict} =
             Custyard.MessageDrafts.save(
               current_scope,
               ctx.sent.thread_id,
               %{reply_text: "Stale copy"},
               draft.lock_version
             )
  end

  defp assert_scope_denied(ctx, stale_scope) do
    assert_raise Ecto.NoResultsError, fn ->
      DataSubjects.export(stale_scope, "pat@example.com", ctx.org.id)
    end

    for operation <- [:erase_participation, :erase_subject] do
      assert {:error, :unauthorized} =
               apply(DataSubjects, operation, [stale_scope, "pat@example.com", ctx.org.id])
    end

    assert Repo.reload!(ctx.sent).body == "I wrote this"
    assert Repo.reload!(ctx.cc).cc_addresses == ctx.cc.cc_addresses
  end

  test "a rotated staff session cannot export or erase", ctx do
    stale_scope = scope(ctx.org)

    Repo.get!(Custyard.StaffAccount, stale_scope.staff_id)
    |> Ecto.Changeset.change(session_claim: Custyard.StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert_scope_denied(ctx, stale_scope)
  end

  test "a demoted administrator cannot export or erase with an old scope", ctx do
    stale_scope = scope(ctx.org)

    Repo.get!(Custyard.StaffAccount, stale_scope.staff_id)
    |> Custyard.StaffAccount.role_changeset(%{role: "agent"})
    |> Repo.update!()

    assert_scope_denied(ctx, stale_scope)
  end

  test "a suspended tenant cannot export or erase through staff authority", ctx do
    stale_scope = scope(ctx.org)

    Repo.get!(Custyard.Tenant, ctx.org.tenant_id)
    |> Ecto.Changeset.change(status: "suspended")
    |> Repo.update!()

    assert_scope_denied(ctx, stale_scope)
  end

  test "erasure revalidates membership after acquiring the staff lock", ctx do
    stale_scope = scope(ctx.org)

    Repo.query!("""
    CREATE TRIGGER demote_dsar_staff AFTER UPDATE OF updated_at ON staff_accounts
    WHEN NEW.id = #{stale_scope.staff_id}
    BEGIN UPDATE staff_accounts SET role = 'agent' WHERE id = NEW.id; END
    """)

    assert {:error, :unauthorized} =
             DataSubjects.erase_subject(stale_scope, "pat@example.com", ctx.org.id)

    assert Repo.reload!(ctx.sent).body == "I wrote this"
    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "a synthetic staff scope is denied while local maintenance uses its explicit capability",
       ctx do
    synthetic = %Custyard.Scope{tenant_id: ctx.org.tenant_id, role: "admin"}
    assert_scope_denied(ctx, synthetic)
    local = %Custyard.DataSubjects.LocalAuthority{tenant_id: ctx.org.tenant_id}
    assert %{messages: [_ | _]} = DataSubjects.export(local, "pat@example.com", ctx.org.id)
  end

  test "personal customer identity is anonymized and future mail creates a new customer", ctx do
    assert {:ok, personal, contact} =
             SenderMatcher.match_within_tenant(
               "Alice <alice@gmail.com>",
               ctx.org.tenant_id
             )

    other_contact =
      insert_contact(organization_id: personal.id, email: "bob@example.com", name: "Bob")

    foreign =
      insert_organization(
        tenant_id: insert_tenant().id,
        identity_kind: :email,
        identity_value: "alice@gmail.com",
        name: "Alice elsewhere",
        domain: nil
      )

    assert {:ok, _} = DataSubjects.erase_subject(scope(personal), "alice@gmail.com", personal.id)
    erased = Repo.reload!(personal)
    assert erased.identity_kind == :manual
    refute erased.identity_value == "alice@gmail.com"
    assert erased.name == "Erased customer"
    refute inspect(Map.from_struct(erased)) =~ "alice@gmail.com"
    refute inspect(Map.from_struct(erased)) =~ "Alice"
    refute Repo.get(Contact, contact.id)
    assert Repo.reload!(other_contact).name == "Bob"
    assert Repo.reload!(foreign).identity_value == "alice@gmail.com"

    assert {:ok, fresh, _} =
             SenderMatcher.match_within_tenant(
               "Alice <alice@gmail.com>",
               personal.tenant_id
             )

    refute fresh.id == personal.id
  end

  test "business customer identity remains while matching prospect credentials are erased",
       _ctx do
    business = insert_organization(name: "Business", domain: "business.example")
    contact = insert_contact(organization_id: business.id, email: "alice@gmail.com")

    thread =
      insert_thread(
        organization_id: business.id,
        contact_id: contact.id,
        source: :public_intake
      )

    prospect =
      insert_prospect(thread_id: thread.id, email: "alice@gmail.com", notify_on_reply: true)

    assert {:ok, pending_claim, _} =
             Custyard.Slugs.claim("pending-business", "alice@gmail.com", thread)

    second = insert_thread(organization_id: business.id, source: :public_intake)

    assert {:ok, retained_slug, _} =
             Custyard.Slugs.claim("retained-business", "alice@gmail.com", second)

    retained_slug
    |> Ecto.Changeset.change(
      status: :provisioned,
      organization_id: business.id,
      confirmation_token_hash: nil,
      expires_at: nil
    )
    |> Repo.update!()

    assert {:ok, _} = DataSubjects.erase_subject(scope(business), "alice@gmail.com", business.id)
    assert Repo.reload!(business).name == "Business"
    assert Repo.reload!(business).identity_kind == :domain
    assert Repo.reload!(business).identity_value == "business.example"
    erased = Repo.reload!(prospect)
    refute Repo.get(Custyard.Slug, pending_claim.id)
    assert Repo.reload!(retained_slug).slug == "retained-business"
    assert Repo.reload!(retained_slug).email == nil
    assert is_nil(erased.email)
    refute erased.notify_on_reply
    assert erased.revoked_at
    loaded = Repo.reload!(thread) |> Repo.preload([:contact, :prospect])
    assert {:error, :no_recipient_email} = Outbound.reply_recipient(loaded)
  end

  test "erasure scrubs sender and subject audit fields while preserving operational evidence",
       ctx do
    # Seed rows as stored before payload minimization; the changeset now omits
    # these keys from every new event.
    own =
      legacy_audit(%{
        organization_id: ctx.org.id,
        thread_id: ctx.sent.thread_id,
        payload: %{
          "sender_email" => "Pat <pat@example.com>",
          "subject" => "Pat private subject",
          "operation_id" => "keep",
          "actor_role" => "agent"
        }
      })

    associated =
      legacy_audit(%{
        thread_id: ctx.sent.thread_id,
        payload: %{
          "from" => "staff@example.com",
          "subject" => "Pat copied subject",
          "event_id" => "keep too"
        }
      })

    unrelated_thread = insert_thread(organization_id: ctx.org.id)

    unrelated =
      legacy_audit(%{
        organization_id: ctx.org.id,
        thread_id: unrelated_thread.id,
        payload: %{
          "sender_email" => "someone@example.com",
          "subject" => "Another person's subject"
        }
      })

    another_customer =
      legacy_audit(%{
        thread_id: ctx.foreign.thread_id,
        payload: %{"sender_email" => "pat@example.com", "subject" => "Different customer"}
      })

    foreign_customer = insert_organization(tenant_id: insert_tenant().id)

    foreign =
      legacy_audit(%{
        organization_id: foreign_customer.id,
        tenant_id: foreign_customer.tenant_id,
        payload: %{"sender_email" => "pat@example.com", "subject" => "Different tenant"}
      })

    assert {:ok, _} = DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

    assert Repo.reload!(own).payload == %{
             "sender_email" => "[ERASED]",
             "subject" => "[ERASED]",
             "operation_id" => "keep",
             "actor_role" => "agent"
           }

    # A thread the person wrote in but does not own keeps its subject, as the
    # thread row itself does; only rows that name the person are redacted.
    assert Repo.reload!(associated).payload == associated.payload
    assert Repo.reload!(unrelated).payload == unrelated.payload
    assert Repo.reload!(another_customer).payload == another_customer.payload
    assert Repo.reload!(foreign).payload == foreign.payload
  end

  test "erasure removes unassigned rejected mail from the same tenant without touching other customer identities",
       ctx do
    own_route = insert_inbound_route(tenant_id: ctx.org.tenant_id)
    foreign_route = insert_inbound_route(tenant_id: insert_tenant().id)
    other = insert_organization()

    rows =
      for {route, organization_id} <- [
            {own_route, nil},
            {own_route, other.id},
            {foreign_route, nil}
          ] do
        %InboundChannelRejection{}
        |> InboundChannelRejection.changeset(%{
          tenant_id: route.tenant_id,
          inbound_route_id: route.id,
          organization_id: organization_id,
          classification: :no_channel,
          sender_email: "Pat <pat@example.com>",
          subject: "Private subject"
        })
        |> Repo.insert!()
      end

    [unassigned, other_customer, foreign] = rows

    assert {:ok, %{rejections_removed: 1}} =
             DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

    refute Repo.get(InboundChannelRejection, unassigned.id)
    assert Repo.get(InboundChannelRejection, other_customer.id)
    assert Repo.get(InboundChannelRejection, foreign.id)
  end

  test "participations finds every role, case-insensitively, inside the organization", ctx do
    found = DataSubjects.participations(scope(ctx.org), " Pat@Example.com ", ctx.org.id)
    by_id = Map.new(found, &{&1.message.id, &1.roles})

    assert by_id[ctx.sent.id] == [:sender]
    assert by_id[ctx.cc.id] == [:cc]
    assert by_id[ctx.reply_to.id] == [:to, :reply_to]
    refute Map.has_key?(by_id, ctx.unrelated.id)
    refute Map.has_key?(by_id, ctx.foreign.id)
  end

  test "export includes the body only for messages the person sent", ctx do
    export = DataSubjects.export(scope(ctx.org), "pat@example.com", ctx.org.id)
    assert export.email == "pat@example.com"
    assert export.organization_id == ctx.org.id

    by_id = Map.new(export.messages, &{&1.message_id, &1})
    assert by_id[ctx.sent.id].body == "I wrote this"
    assert by_id[ctx.sent.id].sender == "Pat <pat@example.com>"
    assert by_id[ctx.cc.id].body == nil
    assert by_id[ctx.cc.id].sender == nil
    assert by_id[ctx.cc.id].subject == "Invoice"
    assert Jason.encode!(export)
  end

  test "erase_participation scrubs recipients and Reply-To but not messages they sent", ctx do
    assert {:ok, %{erased: 2, sent_by_subject: 1}} =
             DataSubjects.erase_participation(scope(ctx.org), "pat@example.com", ctx.org.id)

    assert Repo.get!(Message, ctx.cc.id).cc_addresses == ["boss@customer.example"]
    reply_to = Repo.get!(Message, ctx.reply_to.id)
    assert reply_to.to_addresses == ["help@acme.example"]
    assert reply_to.reply_to == nil
    assert Repo.get!(Message, ctx.sent.id).sender_email == "Pat <pat@example.com>"
    assert Repo.get!(Message, ctx.foreign.id).cc_addresses == ["pat@example.com"]

    assert DataSubjects.participations(scope(ctx.org), "pat@example.com", ctx.org.id)
           |> Enum.map(& &1.roles) == [[:sender]]

    [event] =
      Repo.all(Ecto.Query.from(e in AuditEvent, where: e.event_type == :data_subject_erasure))

    assert event.organization_id == ctx.org.id
    assert event.payload == %{"erased" => 2, "sent_by_subject" => 1}
    refute inspect(event) =~ "pat@example.com"
  end

  test "sender wildcard characters are literal and matching roles agree", ctx do
    exact =
      insert_message(
        thread_id: ctx.cc.thread_id,
        sender_email: " Person <a_%!@example.com> "
      )

    unrelated =
      insert_message(
        thread_id: ctx.cc.thread_id,
        sender_email: "Person <aZanything!@example.com>"
      )

    recipient =
      insert_message(
        thread_id: ctx.cc.thread_id,
        sender_email: "someone@example.com",
        cc_addresses: [" A_%!@example.com "]
      )

    found = DataSubjects.participations(scope(ctx.org), "a_%!@example.com", ctx.org.id)

    assert Map.new(found, &{&1.message.id, &1.roles}) == %{
             exact.id => [:sender],
             recipient.id => [:cc]
           }

    refute Enum.any?(found, &(&1.message.id == unrelated.id))

    assert {:ok, %{erased: 1, sent_by_subject: 1}} =
             DataSubjects.erase_participation(scope(ctx.org), "a_%!@example.com", ctx.org.id)

    assert Repo.get!(Message, recipient.id).cc_addresses == []
  end

  test "successive subject erasures preserve each other's recipient removals", ctx do
    assert {:ok, _} =
             DataSubjects.erase_participation(scope(ctx.org), "pat@example.com", ctx.org.id)

    assert {:ok, %{erased: 1, sent_by_subject: 0}} =
             DataSubjects.erase_participation(scope(ctx.org), "boss@customer.example", ctx.org.id)

    assert Repo.get!(Message, ctx.cc.id).cc_addresses == []

    assert {:ok, %{erased: 0, sent_by_subject: 1}} =
             DataSubjects.erase_participation(scope(ctx.org), "pat@example.com", ctx.org.id)
  end

  test "audit insert failure rolls back recipient erasure", ctx do
    # Force the actual database write to fail rather than replacing the audit
    # module; this proves the message updates and audit share a transaction.
    Repo.query!("""
    CREATE TRIGGER reject_dsar_audit BEFORE INSERT ON audit_events
    WHEN NEW.event_type = 'data_subject_erasure'
    BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END
    """)

    try do
      assert_raise Exqlite.Error, fn ->
        DataSubjects.erase_participation(scope(ctx.org), "pat@example.com", ctx.org.id)
      end

      assert Repo.get!(Message, ctx.cc.id).cc_addresses == ctx.cc.cc_addresses
      assert Repo.get!(Message, ctx.reply_to.id).reply_to == "pat@example.com"
    after
      Repo.query!("DROP TRIGGER reject_dsar_audit")
    end
  end

  test "erase_participation removes the address's delivery outcomes in the organization", ctx do
    kept =
      insert_recipient_status(
        message_id: ctx.cc.id,
        address: "boss@customer.example",
        role: :cc,
        status: :delivered
      )

    insert_recipient_status(message_id: ctx.cc.id, address: "pat@example.com", role: :cc)
    foreign = insert_recipient_status(message_id: ctx.foreign.id, address: "pat@example.com")

    assert {:ok, _} =
             DataSubjects.erase_participation(scope(ctx.org), "Pat@Example.com", ctx.org.id)

    remaining = Repo.all(MessageRecipientStatus) |> Enum.map(& &1.id) |> Enum.sort()
    assert remaining == Enum.sort([kept.id, foreign.id])
  end

  describe "erase_subject/2" do
    setup ctx do
      pat = insert_contact(organization_id: ctx.org.id, email: "Pat@Example.com", name: "Pat")

      own =
        insert_thread(organization_id: ctx.org.id, contact_id: pat.id, subject: "My order")

      own_message =
        insert_message(
          thread_id: own.id,
          sender_email: "pat@example.com",
          to_addresses: ["help@acme.example"],
          body: "Order 42 for Pat",
          message_id: "<pat-1@example.com>"
        )

      reply =
        insert_message(
          thread_id: own.id,
          source: :staff,
          sender_email: "help@acme.example",
          to_addresses: ["pat@example.com"],
          body: "Thanks Pat"
        )

      own_message
      |> Ecto.Changeset.change(html_body: "<p>Order 42</p>", authentication: %{"dkim" => "pass"})
      |> Repo.update!()

      Repo.insert!(%MessageAttachment{
        tenant_id: own_message.tenant_id,
        message_id: own_message.id,
        position: 0,
        descriptor_hash: String.duplicate("a", 64),
        state: :pending
      })

      route = insert_inbound_route(organization_id: ctx.org.id)

      Repo.insert!(%InboundChannelRejection{
        tenant_id: ctx.org.tenant_id,
        organization_id: ctx.org.id,
        inbound_route_id: route.id,
        classification: :no_channel,
        sender_email: "Pat <pat@example.com>",
        subject: "Lost mail"
      })

      %{pat: pat, own: own, own_message: own_message, reply: reply}
    end

    test "removes the delivery outcomes of the person's messages and address", ctx do
      insert_recipient_status(
        message_id: ctx.own_message.id,
        address: "help@acme.example",
        role: :to,
        status: :delivered
      )

      insert_recipient_status(message_id: ctx.reply.id, address: "pat@example.com", role: :to)

      kept =
        insert_recipient_status(
          message_id: ctx.reply.id,
          address: "boss@customer.example",
          role: :cc,
          status: :delivered
        )

      assert {:ok, _} = DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert Repo.all(MessageRecipientStatus) |> Enum.map(& &1.id) == [kept.id]
    end

    test "erasure revokes credentials attributed to the erased contact", ctx do
      assert {:ok, credential, token} =
               Custyard.PortalCredentials.issue(
                 Custyard.Scope.for_staff(
                   insert_staff_account(tenant_id: ctx.org.tenant_id, role: "admin"),
                   Custyard.Tenants.get_tenant!(ctx.org.tenant_id)
                 ),
                 ctx.org.id,
                 ctx.pat.id
               )

      assert {:ok, _} = DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert {:error, :not_found} =
               Custyard.PortalCredentials.authenticate(token, ctx.org.tenant_id)

      assert Repo.reload!(credential).contact_id == nil
    end

    test "erases the person's messages, contact, subjects and rejections", ctx do
      assert {:ok, counts} =
               DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert counts == %{
               erased: 3,
               messages_erased: 2,
               attachments_removed: 1,
               threads_retitled: 1,
               contacts_removed: 1,
               rejections_removed: 1,
               audit_events_redacted: 0
             }

      for id <- [ctx.sent.id, ctx.own_message.id] do
        message = Repo.get!(Message, id)
        assert message.body == ""
        assert message.deleted_at
        assert message.sender_email == nil
        assert message.html_body == nil
        assert message.to_addresses == []
        assert message.authentication == nil
      end

      assert Repo.get!(Message, ctx.own_message.id).message_id == "<pat-1@example.com>"
      assert Repo.aggregate(MessageAttachment, :count) == 0
      refute Repo.get(Contact, ctx.pat.id)

      own = Repo.get!(Thread, ctx.own.id)
      assert own.subject == "(erased)"
      assert own.contact_id == nil
      assert Repo.aggregate(InboundChannelRejection, :count) == 0
    end

    # The erasure removes the rows; the content they pointed at is removed by
    # the orphan sweep once no other row of the tenant names it.
    test "the content of the person's attachments goes with the next orphan sweep", ctx do
      {:ok, [only_pat, also_alice]} =
        Attachments.fetch_for_message(ctx.sent, [
          %{filename: "passport.txt", content: "only Pat sent this"},
          %{filename: "terms.txt", content: "Alice attached this too"}
        ])

      {:ok, [kept]} =
        Attachments.fetch_for_message(ctx.cc, [
          %{filename: "terms.txt", content: "Alice attached this too"}
        ])

      Repo.update_all(StoredFile,
        set: [completed_at: DateTime.add(DateTime.utc_now(:second), -48 * 3600, :second)]
      )

      assert Attachments.sweep_orphan_files() == 0
      assert {:ok, _} = DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)
      refute Repo.get(MessageAttachment, only_pat.id)
      refute Repo.get(MessageAttachment, also_alice.id)

      assert Attachments.sweep_orphan_files() == 1
      refute Files.get(ctx.org.tenant_id, :attachment, only_pat.sha256)
      assert Files.read(Attachments.stored_file(kept)) == {:ok, "Alice attached this too"}
      assert [%StoredFile{}] = Repo.all(StoredFile)
    end

    # An upgraded deployment still has the files an earlier release wrote to
    # the attachment directory. The erasure has to reach those too.
    @tag :tmp_dir
    test "the files an earlier release left on disk go with the next sweep", ctx do
      {:ok, [only_pat, also_alice]} =
        Attachments.fetch_for_message(ctx.sent, [
          %{filename: "passport.txt", content: "only Pat sent this"},
          %{filename: "terms.txt", content: "Alice attached this too"}
        ])

      {:ok, [_kept]} =
        Attachments.fetch_for_message(ctx.cc, [
          %{filename: "terms.txt", content: "Alice attached this too"}
        ])

      [pat_file, shared_file] =
        for %{sha256: sha} <- [only_pat, also_alice] do
          path =
            Path.join([ctx.tmp_dir, "#{ctx.org.tenant_id}", binary_part(sha, 0, 2), sha])

          File.mkdir_p!(Path.dirname(path))
          File.write!(path, "as an earlier release wrote it")
          File.touch!(path, System.os_time(:second) - 48 * 3600)
          path
        end

      assert Attachments.sweep_legacy_files(attachment_dir: ctx.tmp_dir) == 0
      assert {:ok, _} = DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert Attachments.sweep_legacy_files(attachment_dir: ctx.tmp_dir) == 1
      refute File.exists?(pat_file)
      assert File.exists?(shared_file)
    end

    test "keeps staff replies, without the person's address", ctx do
      DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      reply = Repo.get!(Message, ctx.reply.id)
      assert reply.body == "Thanks Pat"
      assert reply.to_addresses == []
      assert reply.deleted_at == nil
    end

    test "leaves other people and other organizations alone", ctx do
      DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert Repo.get!(Message, ctx.cc.id).body == "Alice wrote this"
      assert Repo.get!(Message, ctx.cc.id).cc_addresses == ["boss@customer.example"]
      assert Repo.get!(Message, ctx.unrelated.id).deleted_at == nil
      assert Repo.get!(Message, ctx.foreign.id).cc_addresses == ["pat@example.com"]
      assert Repo.get!(Thread, ctx.sent.thread_id).subject == "Invoice"
    end

    test "redacts legacy audit correspondence in scope and preserves the action evidence", ctx do
      # Seed old persisted records directly, bypassing the new-payload schema.
      legacy =
        legacy_audit(%{
          organization_id: ctx.org.id,
          thread_id: ctx.own.id,
          payload: %{
            "sender_email" => "Pat <PAT@example.com>",
            "subject" => "My order",
            "nested" => [%{"body" => "Order 42 for Pat"}],
            "staff_email" => "staff@example.com",
            "staff_id" => 17,
            "from" => "sent",
            "to" => "failed"
          }
        })

      unscoped_legacy =
        legacy_audit(%{
          thread_id: ctx.own.id,
          payload: %{"email" => "pat@example.com", "subject" => "Old release"}
        })

      shared =
        legacy_audit(%{
          organization_id: ctx.org.id,
          thread_id: ctx.sent.thread_id,
          payload: %{
            "sender_email" => "pat@example.com",
            "subject" => "Shared thread",
            "staff_email" => "staff@example.com"
          }
        })

      assert {:ok, counts} =
               DataSubjects.erase_subject(scope(ctx.org), " PAT@example.com ", ctx.org.id)

      assert counts.audit_events_redacted == 3

      reloaded = Repo.get!(AuditEvent, legacy.id)
      assert %{reloaded | payload: legacy.payload} == legacy
      assert reloaded.payload["sender_email"] == "[ERASED]"
      assert reloaded.payload["subject"] == "[ERASED]"
      assert reloaded.payload["nested"] == [%{"body" => "[ERASED]"}]
      assert reloaded.payload["staff_email"] == "staff@example.com"
      assert reloaded.payload["staff_id"] == 17
      assert reloaded.payload["from"] == "sent"
      assert reloaded.payload["to"] == "failed"
      assert Repo.get!(AuditEvent, shared.id).payload["subject"] == "[ERASED]"
      assert Repo.get!(AuditEvent, unscoped_legacy.id).payload["email"] == "[ERASED]"

      audit = Repo.get_by!(AuditEvent, event_type: :data_subject_erasure)
      assert audit.payload["audit_events_redacted"] == 3

      assert audit.payload["redacted_audit_event_ids"] == [
               legacy.id,
               unscoped_legacy.id,
               shared.id
             ]

      refute Jason.encode!(audit.payload) =~ "pat@example.com"
    end

    test "leaves unrelated organizations, tenant evidence and staff actions intact", ctx do
      other_tenant =
        %Custyard.Tenant{}
        |> Custyard.Tenant.changeset(%{
          name: "Other tenant",
          slug: "audit-other-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      other_org = insert_organization(tenant_id: other_tenant.id)
      other_thread = insert_thread(organization_id: other_org.id)

      records = [
        legacy_audit(%{
          organization_id: other_org.id,
          thread_id: other_thread.id,
          message_id: "<pat@example.com>",
          payload: %{"sender_email" => "pat@example.com", "subject" => "Other tenant"}
        }),
        legacy_audit(%{
          organization_id: ctx.org.id,
          thread_id: ctx.sent.thread_id,
          payload: %{"sender_email" => "alice@example.com", "subject" => "Alice's thread"}
        }),
        legacy_audit(%{
          payload: %{"sender_email" => "pat@example.com", "subject" => "No organization scope"}
        }),
        legacy_audit(%{
          event_type: :acknowledgment_replayed,
          organization_id: ctx.org.id,
          message_id: "<pat@example.com>",
          payload: %{
            "submission_id" => "pat@example.com",
            "body_sha256" => String.duplicate("a", 64)
          }
        }),
        legacy_audit(%{
          event_type: :staff_created,
          organization_id: ctx.org.id,
          message_id: "<pat@example.com>",
          payload: %{"email" => "pat@example.com", "staff_id" => 17}
        })
      ]

      assert {:ok, counts} =
               DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert counts.audit_events_redacted == 0
      for record <- records, do: assert(Repo.get!(AuditEvent, record.id) == record)
    end

    test "erases matching Message-IDs and nested legacy content without matching other mailboxes",
         ctx do
      target =
        legacy_audit(%{
          organization_id: ctx.org.id,
          message_id: "<PAT@example.com>",
          payload: nil
        })

      nested =
        legacy_audit(%{
          organization_id: ctx.org.id,
          payload: %{
            "envelope" => %{"sender_email" => "pat@example.com", "subject" => "Private subject"}
          }
        })

      embedded =
        legacy_audit(%{
          organization_id: ctx.org.id,
          payload: %{"reason" => "Cannot deliver to PAT@example.com."}
        })

      triaged =
        legacy_audit(%{
          event_type: :inbound_triaged,
          organization_id: ctx.org.id,
          message_id: "<pat@example.com>",
          payload: %{"class" => "no_channel", "route_id" => 7}
        })

      unrelated =
        for address <- ["notpat@example.com", "pat@example.com.au", "pat@example.com-other"] do
          legacy_audit(%{
            organization_id: ctx.org.id,
            message_id: "<#{address}>",
            payload: %{"sender_email" => address, "subject" => "Other person's subject"}
          })
        end

      nullable = legacy_audit(%{organization_id: ctx.org.id, payload: nil})

      assert {:ok, counts} =
               DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      assert counts.audit_events_redacted == 4
      assert Repo.get!(AuditEvent, triaged.id).message_id == "[ERASED]"
      assert Repo.get!(AuditEvent, triaged.id).payload == triaged.payload
      assert Repo.get!(AuditEvent, target.id).message_id == "[ERASED]"
      assert Repo.get!(AuditEvent, target.id).payload == nil
      assert Repo.get!(AuditEvent, nested.id).payload["envelope"]["subject"] == "[ERASED]"
      assert Repo.get!(AuditEvent, embedded.id).payload["reason"] == "[ERASED]"
      for record <- [nullable | unrelated], do: assert(Repo.get!(AuditEvent, record.id) == record)

      assert {:ok, %{audit_events_redacted: 0}} =
               DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)
    end

    test "audit redaction rolls back when the erasure evidence cannot be persisted", ctx do
      legacy =
        legacy_audit(%{
          organization_id: ctx.org.id,
          thread_id: ctx.own.id,
          payload: %{"sender_email" => "pat@example.com", "subject" => "My order"}
        })

      Repo.query!("""
      CREATE TRIGGER refuse_contact_audit BEFORE INSERT ON audit_events
      WHEN NEW.event_type = 'data_subject_erasure'
      BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END
      """)

      try do
        assert_raise Exqlite.Error, fn ->
          DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)
        end

        assert Repo.get!(AuditEvent, legacy.id) == legacy
        assert Repo.get!(Contact, ctx.pat.id)
        assert Repo.get!(Message, ctx.own_message.id).body == "Order 42 for Pat"
      after
        Repo.query!("DROP TRIGGER refuse_contact_audit")
      end
    end

    test "audit redaction requires an explicit transaction and valid address", ctx do
      assert_raise ArgumentError, "audit redaction requires a transaction", fn ->
        AuditEvent.redact_subject_data("pat@example.com", ctx.org.id, [])
      end

      assert_raise ArgumentError, "audit redaction requires a valid address", fn ->
        Repo.transaction(fn -> AuditEvent.redact_subject_data("", ctx.org.id, []) end)
      end
    end

    test "writes one audit event with counts and no address", ctx do
      DataSubjects.erase_subject(scope(ctx.org), "pat@example.com", ctx.org.id)

      [event] = Repo.all(AuditEvent)
      assert event.event_type == :data_subject_erasure
      assert event.payload["messages_erased"] == 2
      refute Jason.encode!(event.payload) =~ "pat"
    end
  end

  # Rows as earlier releases stored them, bypassing the payload allowlist.
  # Every stored row carries its tenant; default to the audited customer's.
  defp legacy_audit(attrs) do
    tenant_id =
      case attrs do
        %{tenant_id: id} -> id
        %{organization_id: id} -> Repo.get!(Custyard.Organization, id).tenant_id
        _ -> Custyard.Factory.factory_tenant_id()
      end

    struct(
      AuditEvent,
      Map.merge(%{event_type: :webhook_received, source: "email", tenant_id: tenant_id}, attrs)
    )
    |> Repo.insert!()
  end
end

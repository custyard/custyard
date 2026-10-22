defmodule Custyard.DataSubjectsTest do
  @moduledoc "DSAR coverage for CC participants (spec-inbound-channels, Privacy)."
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{AuditEvent, DataSubjects, Message, Repo}

  setup do
    org = insert_organization()
    other_org = insert_organization()
    conv = insert_conversation(organization_id: org.id, subject: "Invoice")
    other_conv = insert_conversation(organization_id: other_org.id)

    sent =
      insert_message(
        conversation_id: conv.id,
        sender_email: "Pat <pat@example.com>",
        to_addresses: ["help@acme.example"],
        body: "I wrote this"
      )

    cc =
      insert_message(
        conversation_id: conv.id,
        sender_email: "alice@customer.example",
        to_addresses: ["help@acme.example"],
        cc_addresses: ["PAT@example.com", "boss@customer.example"],
        body: "Alice wrote this"
      )

    reply_to =
      insert_message(
        conversation_id: conv.id,
        sender_email: "alice@customer.example",
        to_addresses: ["pat@example.com", "help@acme.example"],
        reply_to: "pat@example.com",
        body: "Alice again"
      )

    unrelated = insert_message(conversation_id: conv.id, sender_email: "zed@example.com")
    foreign = insert_message(conversation_id: other_conv.id, cc_addresses: ["pat@example.com"])

    %{org: org, sent: sent, cc: cc, reply_to: reply_to, unrelated: unrelated, foreign: foreign}
  end

  test "participations finds every role, case-insensitively, inside the organization", ctx do
    found = DataSubjects.participations(" Pat@Example.com ", ctx.org.id)
    by_id = Map.new(found, &{&1.message.id, &1.roles})

    assert by_id[ctx.sent.id] == [:sender]
    assert by_id[ctx.cc.id] == [:cc]
    assert by_id[ctx.reply_to.id] == [:to, :reply_to]
    refute Map.has_key?(by_id, ctx.unrelated.id)
    refute Map.has_key?(by_id, ctx.foreign.id)
  end

  test "export includes the body only for messages the person sent", ctx do
    export = DataSubjects.export("pat@example.com", ctx.org.id)
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
             DataSubjects.erase_participation("pat@example.com", ctx.org.id)

    assert Repo.get!(Message, ctx.cc.id).cc_addresses == ["boss@customer.example"]
    reply_to = Repo.get!(Message, ctx.reply_to.id)
    assert reply_to.to_addresses == ["help@acme.example"]
    assert reply_to.reply_to == nil
    assert Repo.get!(Message, ctx.sent.id).sender_email == "Pat <pat@example.com>"
    assert Repo.get!(Message, ctx.foreign.id).cc_addresses == ["pat@example.com"]

    assert DataSubjects.participations("pat@example.com", ctx.org.id)
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
        conversation_id: ctx.cc.conversation_id,
        sender_email: " Person <a_%!@example.com> "
      )

    unrelated =
      insert_message(
        conversation_id: ctx.cc.conversation_id,
        sender_email: "Person <aZanything!@example.com>"
      )

    recipient =
      insert_message(
        conversation_id: ctx.cc.conversation_id,
        sender_email: "someone@example.com",
        cc_addresses: [" A_%!@example.com "]
      )

    found = DataSubjects.participations("a_%!@example.com", ctx.org.id)

    assert Map.new(found, &{&1.message.id, &1.roles}) == %{
             exact.id => [:sender],
             recipient.id => [:cc]
           }

    refute Enum.any?(found, &(&1.message.id == unrelated.id))

    assert {:ok, %{erased: 1, sent_by_subject: 1}} =
             DataSubjects.erase_participation("a_%!@example.com", ctx.org.id)

    assert Repo.get!(Message, recipient.id).cc_addresses == []
  end

  test "successive subject erasures preserve each other's recipient removals", ctx do
    assert {:ok, _} = DataSubjects.erase_participation("pat@example.com", ctx.org.id)

    assert {:ok, %{erased: 1, sent_by_subject: 0}} =
             DataSubjects.erase_participation("boss@customer.example", ctx.org.id)

    assert Repo.get!(Message, ctx.cc.id).cc_addresses == []

    assert {:ok, %{erased: 0, sent_by_subject: 1}} =
             DataSubjects.erase_participation("pat@example.com", ctx.org.id)
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
        DataSubjects.erase_participation("pat@example.com", ctx.org.id)
      end

      assert Repo.get!(Message, ctx.cc.id).cc_addresses == ctx.cc.cc_addresses
      assert Repo.get!(Message, ctx.reply_to.id).reply_to == "pat@example.com"
    after
      Repo.query!("DROP TRIGGER reject_dsar_audit")
    end
  end
end

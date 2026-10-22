defmodule Custyard.Release.DsarTest do
  # The CLI captures the global stderr device; run alone.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureIO

  alias Custyard.{AuditEvent, Contact, Conversation, InboundChannelRejection}
  alias Custyard.{Message, MessageAttachment, Organization}
  alias Custyard.Release.Dsar

  @email "pat@example.com"

  # Runs a command as bin/dsar would in a running VM, capturing both streams
  # and the exit status.
  defp cli(argv) do
    {{status, out}, err} = with_io(:stderr, fn -> with_io(fn -> Dsar.run(argv) end) end)
    %{status: status, out: out, err: err}
  end

  # Everything an erasure could touch, for "nothing changed" assertions.
  defp state do
    %{
      messages: Repo.all(from(m in Message, order_by: m.id)),
      conversations: Repo.all(from(c in Conversation, order_by: c.id)),
      contacts: Repo.all(from(c in Contact, order_by: c.id)),
      attachments: Repo.all(from(a in MessageAttachment, order_by: a.id)),
      rejections: Repo.all(from(r in InboundChannelRejection, order_by: r.id)),
      audit_events: Repo.all(from(a in AuditEvent, order_by: a.id))
    }
  end

  defp audit_events, do: Repo.all(from(a in AuditEvent, order_by: a.id))

  setup do
    org = insert_organization()
    pat = insert_contact(organization_id: org.id, email: @email, name: "Pat")
    own = insert_conversation(organization_id: org.id, contact_id: pat.id, subject: "My order")
    other = insert_conversation(organization_id: org.id, subject: "Invoice")

    sent =
      insert_message(
        conversation_id: own.id,
        sender_email: "Pat <#{@email}>",
        to_addresses: ["help@acme.example"],
        body: "Order 42 for Pat"
      )

    Repo.insert!(%MessageAttachment{
      message_id: sent.id,
      position: 0,
      descriptor_hash: String.duplicate("a", 64),
      state: :pending
    })

    cc =
      insert_message(
        conversation_id: other.id,
        sender_email: "alice@customer.example",
        to_addresses: ["help@acme.example"],
        cc_addresses: ["PAT@example.com", "boss@customer.example"],
        body: "Alice wrote this"
      )

    route = insert_inbound_route(organization_id: org.id)

    Repo.insert!(%InboundChannelRejection{
      organization_id: org.id,
      inbound_route_id: route.id,
      classification: :no_channel,
      sender_email: "Pat <#{@email}>",
      subject: "Lost mail"
    })

    %{org: org, org_id: Integer.to_string(org.id), pat: pat, own: own, sent: sent, cc: cc}
  end

  describe "usage" do
    test "help prints usage to stdout and succeeds" do
      result = cli(["help"])
      assert result.status == 0
      assert result.out =~ "Usage: bin/dsar ACTION EMAIL --org ID [--yes]"
      assert result.out =~ "erase-contact EMAIL --org ID --yes"
      assert result.err == ""
    end

    test "bad arguments print usage to stderr, change nothing and exit 1", ctx do
      before = state()

      for argv <- [
            [],
            ["bogus", @email, "--org", ctx.org_id],
            ["help", "extra"],
            ["export"],
            ["export", @email],
            ["export", @email, "--org"],
            ["export", @email, "--org", "abc"],
            ["export", @email, "--org", "0"],
            ["export", @email, "--org", "99999999999999999999"],
            ["export", @email, "--org", ctx.org_id, "--org", ctx.org_id],
            ["export", @email, "--org", ctx.org_id, "extra"],
            ["export", @email, "--org", ctx.org_id, "--bogus"],
            ["export", @email, "--org", ctx.org_id, "--yes=maybe"],
            ["erase", @email, "--org", ctx.org_id, "--yes", "--yes"],
            ["erase-contact", @email, "--org", ctx.org_id, "--yes", "--no-yes"]
          ] do
        result = cli(argv)
        assert result.status == 1, "#{inspect(argv)} succeeded"
        assert result.out == "", "#{inspect(argv)} wrote to stdout"
        assert result.err =~ "Usage: bin/dsar", "#{inspect(argv)} did not print usage"
      end

      assert state() == before
    end

    test "an invalid address is refused and never printed", ctx do
      before = state()

      for action <- ["export", "erase", "erase-contact"],
          address <- ["not an address", "pat@", "<pat@example.com>"] do
        result = cli([action, address, "--org", ctx.org_id, "--yes"])
        assert result.status == 1
        assert result.out == ""
        assert result.err == "Error: EMAIL is not a valid email address\n"
        refute result.err =~ "pat"
      end

      assert state() == before
    end

    test "an erasure without --yes is refused and changes nothing", ctx do
      before = state()

      for action <- ["erase", "erase-contact"] do
        result = cli([action, @email, "--org", ctx.org_id])
        assert result.status == 1
        assert result.out == ""
        assert result.err == "Error: #{action} is irreversible; pass --yes to confirm\n"
        refute result.err =~ @email
      end

      assert state() == before
    end

    test "an unknown organization is an error and changes nothing" do
      before = state()
      missing = Repo.aggregate(Organization, :max, :id) + 1

      for argv <- [
            ["export", @email, "--org", "#{missing}"],
            ["erase", @email, "--org", "#{missing}", "--yes"],
            ["erase-contact", @email, "--org", "#{missing}", "--yes"]
          ] do
        result = cli(argv)
        assert result.status == 1
        assert result.out == ""
        assert result.err == "Error: organization #{missing} not found\n"
      end

      assert state() == before
    end
  end

  describe "export" do
    test "prints the person's messages as JSON and changes nothing", ctx do
      before = state()
      result = cli(["export", @email, "--org", ctx.org_id])

      assert result.status == 0
      assert result.err == ""
      assert String.ends_with?(result.out, "\n")

      export = Jason.decode!(result.out)
      assert export["email"] == @email
      assert export["organization_id"] == ctx.org.id

      by_id = Map.new(export["messages"], &{&1["message_id"], &1})
      assert by_id[ctx.sent.id]["roles"] == ["sender"]
      assert by_id[ctx.sent.id]["body"] == "Order 42 for Pat"
      assert by_id[ctx.sent.id]["subject"] == "My order"
      assert by_id[ctx.cc.id]["roles"] == ["cc"]
      assert by_id[ctx.cc.id]["body"] == nil
      assert map_size(by_id) == 2

      assert state() == before
    end

    test "matches the address case-insensitively and takes switches first", ctx do
      result = cli(["--org", ctx.org_id, "export", "PAT@Example.com"])
      assert result.status == 0
      assert length(Jason.decode!(result.out)["messages"]) == 2
    end
  end

  describe "erase" do
    test "removes the address as a recipient and reports what the person sent", ctx do
      result = cli(["erase", @email, "--org", ctx.org_id, "--yes"])

      assert result.status == 0
      assert result.err == ""

      assert result.out ==
               "Removed the address from 1 message(s) as a recipient. " <>
                 "1 message(s) were sent by this address; erase-contact erases those too.\n"

      assert Repo.get!(Message, ctx.cc.id).cc_addresses == ["boss@customer.example"]
      assert Repo.get!(Message, ctx.sent.id).body == "Order 42 for Pat"
      assert Repo.get(Contact, ctx.pat.id)

      assert [%AuditEvent{event_type: :data_subject_erasure, payload: payload}] = audit_events()
      assert payload == %{"erased" => 1, "sent_by_subject" => 1}
    end

    test "accepts the address after -- when it looks like a switch", ctx do
      result = cli(["erase", "--org", ctx.org_id, "--yes", "--", "--odd@example.com"])
      assert result.status == 0
      assert result.out =~ "Removed the address from 0 message(s)"
    end
  end

  describe "erase-contact" do
    test "erases the contact and prints each count", ctx do
      result = cli(["erase-contact", @email, "--org", ctx.org_id, "--yes"])

      assert result.status == 0
      assert result.err == ""

      assert result.out == """
             Address removed as a recipient: 1 message(s)
             Sent messages erased: 1
             Attachments removed: 1
             Contact records removed: 1
             Conversation subjects erased: 1
             Rejection-log entries removed: 1
             """

      sent = Repo.get!(Message, ctx.sent.id)
      assert sent.body == ""
      assert sent.sender_email == nil
      assert sent.deleted_at
      assert Repo.get!(Message, ctx.cc.id).cc_addresses == ["boss@customer.example"]
      refute Repo.get(Contact, ctx.pat.id)
      assert Repo.get!(Conversation, ctx.own.id).subject == "(erased)"
      assert Repo.aggregate(MessageAttachment, :count) == 0
      assert Repo.aggregate(InboundChannelRejection, :count) == 0

      assert [%AuditEvent{event_type: :data_subject_erasure, payload: payload}] = audit_events()
      assert payload["messages_erased"] == 1
      refute Jason.encode!(payload) =~ "pat"
    end
  end
end

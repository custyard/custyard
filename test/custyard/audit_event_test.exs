defmodule Custyard.AuditEventTest do
  use Custyard.DataCase, async: true

  alias Custyard.AuditEvent
  alias Custyard.AuditEvent.Payload

  import Custyard.Factory

  test "every audit event has an explicitly reviewed payload schema" do
    assert MapSet.new(Payload.event_types()) == MapSet.new(AuditEvent.event_types())
  end

  describe "event_types/0" do
    test "returns list of valid event types" do
      assert AuditEvent.event_types() == [
               :instance_admin_created,
               :instance_admin_removed,
               :installation_configured,
               :webhook_received,
               :webhook_processed,
               :webhook_error,
               :slug_released,
               :prospect_converted,
               :staff_created,
               :staff_removed,
               :tenant_created,
               :tenant_status_changed,
               :tenant_host_added,
               :tenant_host_removed,
               :acknowledgment_replayed,
               :acknowledgment_binding_created,
               :delivery_status_updated,
               :reply_queued,
               :internal_note_created,
               :reply_retried,
               :outbound_pause_changed,
               :thread_state_changed,
               :sender_ignored,
               :channel_created,
               :channel_updated,
               :channel_deleted,
               :channel_state_changed,
               :channel_token_rotated,
               :channel_token_revealed,
               :channel_verification_captured,
               :channel_sending_domain_checked,
               :channel_quiet,
               :inbound_triaged,
               :data_subject_erasure
             ]
    end
  end

  describe "changeset/2" do
    test "valid with required fields" do
      attrs = build_audit_event()
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      assert changeset.valid?
    end

    test "requires event_type" do
      attrs = build_audit_event() |> Map.delete(:event_type)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).event_type
    end

    test "requires source" do
      attrs = build_audit_event() |> Map.delete(:source)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source
    end

    test "validates event_type is one of allowed values" do
      attrs = build_audit_event() |> Map.put(:event_type, :invalid_type)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).event_type
    end

    test "validates source max length" do
      attrs = build_audit_event(source: String.duplicate("a", 101))
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      refute changeset.valid?
      assert "should be at most 100 character(s)" in errors_on(changeset).source
    end

    test "source accepts fixed application channels and adapters, rejecting private content" do
      sources =
        ~w(email lettermint zendesk intercom slack portal webhook unknown staff instance_admin system acknowledgments lmtp cli mix console inbound_channels dsar test)

      for source <- sources do
        assert AuditEvent.changeset(%AuditEvent{}, build_audit_event(source: source)).valid?
      end

      for source <- Custyard.Webhooks.Registry.sources() do
        assert Atom.to_string(source) in sources
      end

      for source <- [
            "PRIVATE_SOURCE_CANARY@example.com",
            "unregistered-source",
            "token/PRIVATE_SOURCE_CANARY"
          ] do
        changeset = AuditEvent.changeset(%AuditEvent{}, build_audit_event(source: source))
        refute changeset.valid?
        assert "is invalid" in errors_on(changeset).source
      end
    end

    test "validates message_id max length" do
      attrs = build_audit_event(message_id: String.duplicate("a", 501))
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      refute changeset.valid?
      assert "should be at most 500 character(s)" in errors_on(changeset).message_id
    end

    test "accepts all valid event types" do
      for event_type <- [:webhook_received, :webhook_processed, :webhook_error] do
        attrs = build_audit_event(event_type: event_type)
        changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

        assert changeset.valid?, "expected #{event_type} to be valid"
      end
    end

    test "optional fields can be nil" do
      attrs = build_audit_event(message_id: nil, payload: nil)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      assert changeset.valid?
    end

    test "accepts organization_id" do
      org = insert_organization()
      attrs = build_audit_event(organization_id: org.id)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      assert changeset.valid?
    end

    test "accepts thread_id" do
      conv = insert_thread()
      attrs = build_audit_event(thread_id: conv.id)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      assert changeset.valid?
    end

    test "accepts project_id" do
      project = insert_project()
      attrs = build_audit_event(project_id: project.id)
      changeset = AuditEvent.changeset(%AuditEvent{}, attrs)

      assert changeset.valid?
    end
  end

  describe "create/1" do
    test "inserts audit event with valid attrs" do
      attrs = build_audit_event()
      assert {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.id != nil
      assert audit_event.event_type == :webhook_received
      assert audit_event.source == "email"
    end

    test "returns error changeset with invalid attrs" do
      attrs = build_audit_event() |> Map.delete(:event_type)
      assert {:error, changeset} = AuditEvent.create(attrs)

      refute changeset.valid?
    end

    test "stores the permitted event payload as a map" do
      payload = %{"source" => "email", "timestamp" => "2026-10-31T12:00:00Z"}
      attrs = build_audit_event(payload: payload)

      {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.payload == payload
    end

    test "associates with organization" do
      org = insert_organization()
      attrs = build_audit_event(organization_id: org.id)

      {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.organization_id == org.id
    end

    test "associates with thread" do
      conv = insert_thread()
      attrs = build_audit_event(thread_id: conv.id)

      {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.thread_id == conv.id
    end

    test "sets inserted_at timestamp" do
      attrs = build_audit_event()
      {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.inserted_at != nil
    end
  end

  describe "audit payload privacy" do
    test "the payload boundary is total for nil, malformed and unrecognized input" do
      for malformed <- [nil, "private@example.com", 42, ["private"], {:private, "content"}] do
        assert Payload.minimize(malformed, :webhook_received) == %{}
      end

      assert Payload.minimize(%{"source" => "private@example.com"}, nil) == %{}
      assert Payload.minimize(%{"source" => "email"}, :unrecognized) == %{}
      assert Payload.minimize(DateTime.utc_now(), :webhook_received) == %{}
    end

    test "every event drops undeclared nested payloads and personal content" do
      for type <- AuditEvent.event_types() do
        attrs =
          build_audit_event(
            event_type: type,
            payload: %{
              "email" => "person@example.com",
              "subject" => "Private correspondence",
              "unexpected" => %{"secret" => "credential", "body" => "Customer text"}
            }
          )

        assert {:ok, event} = AuditEvent.create(attrs)
        assert event.payload == %{}
      end
    end

    test "requires typed IDs, finite roles and count-only message lists" do
      assert {:ok, event} =
               AuditEvent.create(
                 build_audit_event(
                   event_type: :staff_removed,
                   payload: %{
                     "staff_id" => "person@example.com",
                     "actor_staff_id" => %{name: "Acme"},
                     "role" => "agent with customer content",
                     "deleted_message_ids" => [7, "person@example.com", -1, 7, 8],
                     "forwarded_message_ids" => ["person@example.com"],
                     "email" => "person@example.com"
                   }
                 )
               )

      assert event.payload == %{
               "staff_id" => nil,
               "actor_staff_id" => nil,
               "role" => nil,
               "deleted_message_ids" => [7, 8],
               "forwarded_message_ids" => []
             }
    end

    test "retains exact contractual acknowledgment identities and body digest" do
      digest = :crypto.hash(:sha256, "exact evidence") |> Base.encode16(case: :lower)

      payload = %{
        "actor" => "staff",
        "staff_id" => 7,
        "source" => "partner.integration",
        "submission_id" => "subject@example.com",
        "body_sha256" => digest,
        "category" => "unmapped_organization",
        "attempt" => 4,
        "outcome" => "replayed"
      }

      assert {:ok, event} =
               AuditEvent.create(
                 build_audit_event(
                   event_type: :acknowledgment_replayed,
                   payload: Map.put(payload, "staff_email", "staff@example.com")
                 )
               )

      assert event.payload == payload
    end

    test "delivery audit data rejects arbitrary provider codes and response strings" do
      assert {:ok, event} =
               AuditEvent.create(
                 build_audit_event(
                   event_type: :delivery_status_updated,
                   payload: %{
                     "event" => "message.failed",
                     "delivery_id" => "event-123",
                     "from" => "sent",
                     "to" => "failed",
                     "reason" => "Refused person@example.com /app/login/verify/SECRET",
                     "reason_code" => "person@example.com",
                     "status_code" => "550 person@example.com",
                     "enhanced_status_code" => "5.1.1 person@example.com",
                     "response" => %{body: "Secret email"}
                   }
                 )
               )

      assert event.payload == %{
               "event" => "message.failed",
               "delivery_id" => "event-123",
               "from" => "sent",
               "to" => "failed",
               "reason_code" => nil,
               "status_code" => nil,
               "enhanced_status_code" => nil
             }
    end

    test "channel changes retain declared field names without field values" do
      assert {:ok, event} =
               AuditEvent.create(
                 build_audit_event(
                   event_type: :channel_updated,
                   payload: %{
                     "channel_id" => 2,
                     "changed" => [
                       "display_name",
                       :imap_password,
                       "person@example.com",
                       %{body: "secret"}
                     ]
                   }
                 )
               )

      assert event.payload == %{"channel_id" => 2, "changed" => ["display_name", "imap_password"]}
    end

    test "a thread state change keeps the staff id and thread states only" do
      assert Payload.minimize(
               %{
                 "staff_id" => 7,
                 "from" => :waiting,
                 "to" => "resolved",
                 "subject" => "Refund request",
                 "staff_email" => "staff@example.com"
               },
               :thread_state_changed
             ) == %{"staff_id" => 7, "from" => "waiting", "to" => "resolved"}

      # A delivery status is not a thread state, and a thread state is not a
      # delivery status.
      assert Payload.minimize(%{"from" => "delivered", "to" => "bounced"}, :thread_state_changed) ==
               %{"from" => nil, "to" => nil}

      assert Payload.minimize(%{"from" => "waiting", "to" => "dormant"}, :delivery_status_updated) ==
               %{"from" => nil, "to" => nil}

      for state <- Custyard.Thread.states() do
        assert Payload.minimize(%{"to" => state}, :thread_state_changed) ==
                 %{"to" => Atom.to_string(state)}
      end
    end

    test "a created tenant and an added hostname keep the admin id and the hostname" do
      for type <- [:tenant_created, :tenant_host_added] do
        assert Payload.minimize(
                 %{
                   "instance_admin_id" => 3,
                   "host_id" => 9,
                   "hostname" => "help.example.com",
                   "name" => "Northwind",
                   "email" => "root@example.com"
                 },
                 type
               ) == %{"instance_admin_id" => 3, "host_id" => 9, "hostname" => "help.example.com"}

        assert Payload.minimize(%{"host_id" => "9", "hostname" => "person@example.com"}, type) ==
                 %{"host_id" => nil, "hostname" => nil}
      end
    end

    test "a created staff account keeps ids, the role and who created it, never the address" do
      assert Payload.minimize(
               %{
                 "staff_id" => 7,
                 "actor_staff_id" => 2,
                 "role" => "agent",
                 "via" => "staff",
                 "email" => "new@example.com"
               },
               :staff_created
             ) == %{"staff_id" => 7, "actor_staff_id" => 2, "role" => "agent", "via" => "staff"}

      assert Payload.minimize(
               %{"instance_admin_id" => 3, "role" => "super_admin", "via" => "new@example.com"},
               :staff_created
             ) == %{"instance_admin_id" => 3, "role" => nil, "via" => nil}
    end

    test "ignoring a sender keeps ids and the flag, never the address" do
      assert Payload.minimize(
               %{
                 "staff_id" => 7,
                 "contact_id" => 12,
                 "ignored" => true,
                 "email" => "person@example.com"
               },
               :sender_ignored
             ) == %{"staff_id" => 7, "contact_id" => 12, "ignored" => true}

      assert Payload.minimize(
               %{"contact_id" => "person@example.com", "ignored" => "yes"},
               :sender_ignored
             ) == %{"contact_id" => nil, "ignored" => nil}
    end
  end
end

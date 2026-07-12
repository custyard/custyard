defmodule Custyard.AuditEventTest do
  use Custyard.DataCase, async: true

  alias Custyard.AuditEvent

  import Custyard.Factory

  describe "event_types/0" do
    test "returns list of valid event types" do
      assert AuditEvent.event_types() == [
               :webhook_received,
               :webhook_processed,
               :webhook_error,
               :slug_released
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

    test "accepts conversation_id" do
      conv = insert_conversation()
      attrs = build_audit_event(conversation_id: conv.id)
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

    test "stores payload as map" do
      payload = %{"key" => "value", "nested" => %{"data" => 123}}
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

    test "associates with conversation" do
      conv = insert_conversation()
      attrs = build_audit_event(conversation_id: conv.id)

      {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.conversation_id == conv.id
    end

    test "sets inserted_at timestamp" do
      attrs = build_audit_event()
      {:ok, audit_event} = AuditEvent.create(attrs)

      assert audit_event.inserted_at != nil
    end
  end
end

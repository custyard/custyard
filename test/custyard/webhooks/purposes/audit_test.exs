defmodule Custyard.Webhooks.Purposes.AuditTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Webhooks.Purposes.Audit
  alias Custyard.{AuditEvent, Repo}

  describe "process/3" do
    test "persists audit event to database" do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      conv = insert_conversation(organization_id: org.id, project_id: project.id)

      normalized = %{
        source: :lettermint,
        sender_email: "alice@example.com",
        subject: "Test webhook",
        message_id: "msg-123@example.com"
      }

      route_context = %{
        organization_id: org.id,
        project_id: project.id
      }

      assert :ok = Audit.process(conv, normalized, route_context)

      event = Repo.get_by!(AuditEvent, conversation_id: conv.id)
      assert event.event_type == :webhook_received
      assert event.source == "lettermint"
      assert event.message_id == "msg-123@example.com"
      assert event.organization_id == org.id
      assert event.project_id == project.id
    end

    test "builds payload with normalized data" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      normalized = %{
        source: :zendesk,
        sender_email: "bob@example.com",
        subject: "Zendesk ticket"
      }

      route_context = %{organization_id: org.id}

      Audit.process(conv, normalized, route_context)

      event = Repo.get_by!(AuditEvent, conversation_id: conv.id)
      assert event.payload["source"] == "zendesk"
      assert event.payload["sender_email"] == "bob@example.com"
      assert event.payload["subject"] == "Zendesk ticket"
      assert Map.has_key?(event.payload, "timestamp")
    end

    test "stores route context in audit event" do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      conv = insert_conversation(organization_id: org.id)

      normalized = %{
        source: :email,
        message_id: "test-msg-id"
      }

      route_context = %{
        organization_id: org.id,
        project_id: project.id
      }

      assert :ok = Audit.process(conv, normalized, route_context)

      event = Repo.get_by!(AuditEvent, conversation_id: conv.id)
      assert event.organization_id == org.id
      assert event.project_id == project.id
    end

    test "handles missing source gracefully" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      normalized = %{
        sender_email: "user@test.com"
      }

      route_context = %{organization_id: org.id}

      assert :ok = Audit.process(conv, normalized, route_context)

      event = Repo.get_by!(AuditEvent, conversation_id: conv.id)
      assert event.source == "unknown"
    end

    test "handles nil message_id" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      normalized = %{
        source: :portal,
        message_id: nil
      }

      route_context = %{organization_id: org.id}

      assert :ok = Audit.process(conv, normalized, route_context)

      event = Repo.get_by!(AuditEvent, conversation_id: conv.id)
      assert event.message_id == nil
    end
  end

  describe "error handling" do
    test "returns :ok even when database insert fails due to validation" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      normalized = %{
        # source is nil which will fail validation when converted to string
        source: nil,
        # Add a very long message_id to trigger validation error
        message_id: String.duplicate("x", 1000)
      }

      route_context = %{organization_id: org.id}

      # Should return :ok despite the validation failure (doesn't block webhook pipeline)
      assert :ok = Audit.process(conv, normalized, route_context)

      # No audit event should be created due to validation failure
      events = Repo.all(AuditEvent)
      refute Enum.any?(events, fn e -> e.conversation_id == conv.id end)
    end

    test "returns :ok when rescue catches exception" do
      # Use a fake conversation struct with an ID that doesn't exist in FK
      fake_conv = %{id: -999_999}

      normalized = %{
        source: :email
      }

      route_context = %{organization_id: nil}

      # Should return :ok even when exception is raised (doesn't block webhook pipeline)
      assert :ok = Audit.process(fake_conv, normalized, route_context)
    end
  end
end

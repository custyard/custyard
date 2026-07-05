defmodule Custyard.Webhooks.Adapters.EmailTest do
  @moduledoc """
  Tests for the Email webhook adapter.

  The Email adapter normalizes Parser.parse output (dual-key maps with
  text/html fields) into the unified Dispatcher format (atom-key maps
  with collapsed body, source: :email, metadata: %{}).

  This adapter bridges the LMTP/IMAP email paths into the same pipeline
  that HTTP webhook sources use.
  """
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Email, as: EmailAdapter

  # Build a dual-key map that matches Parser.parse output format.
  # Parser emits both atom and string keys for compatibility.
  defp parser_output(overrides) do
    base = %{
      from: "alice@example.com",
      to: "support@custyard.test",
      subject: "Test subject",
      text: "Plain text body",
      html: nil,
      message_id: nil,
      in_reply_to: nil,
      references: nil,
      headers: %{},
      attachments: []
    }

    merged = Map.merge(base, overrides)

    # Add string-key duplicates like Parser.add_string_keys does
    merged
    |> Map.put("from", merged.from)
    |> Map.put("to", merged.to)
    |> Map.put("subject", merged.subject)
    |> Map.put("text", merged.text)
    |> Map.put("html", merged.html)
    |> Map.put("headers", merged.headers)
    |> Map.put("attachments", merged.attachments)
  end

  describe "source_name/0" do
    test "returns :email" do
      assert EmailAdapter.source_name() == :email
    end
  end

  describe "verify_signature/3" do
    test "always returns :ok (email auth is handled at transport level)" do
      assert :ok = EmailAdapter.verify_signature(%{}, nil, nil)
      assert :ok = EmailAdapter.verify_signature(%{}, "any-sig", "any-secret")
      assert :ok = EmailAdapter.verify_signature(%{"from" => "a@b.com"}, nil, "secret")
    end
  end

  describe "normalize/1 with dual-key Parser output" do
    test "normalizes text+html email, preferring text for body" do
      headers = %{
        "message-id" => "<msg-001@example.com>",
        "in-reply-to" => "<prev-001@example.com>",
        "references" => "<ref-001@example.com> <ref-002@example.com>",
        "X-Priority" => "1"
      }

      parsed =
        parser_output(%{
          from: "alice@example.com",
          to: "support@custyard.test",
          subject: "Need help with setup",
          text: "Hello, I need assistance.",
          html: "<html><body><p>Hello, I need assistance.</p></body></html>",
          message_id: "<msg-001@example.com>",
          in_reply_to: "<prev-001@example.com>",
          references: "<ref-001@example.com> <ref-002@example.com>",
          headers: headers
        })

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)

      assert normalized.from == "alice@example.com"
      assert normalized.to == "support@custyard.test"
      assert normalized.subject == "Need help with setup"
      assert normalized.body == "Hello, I need assistance."
      assert normalized.message_id == "<msg-001@example.com>"
      assert normalized.in_reply_to == "<prev-001@example.com>"
      assert normalized.references == "<ref-001@example.com> <ref-002@example.com>"
      assert normalized.source == :email
      assert normalized.metadata == %{}
      assert is_map(normalized.headers)
    end

    test "normalizes text-only email (no html)" do
      parsed =
        parser_output(%{
          from: "bob@example.com",
          text: "Just plain text here.",
          html: nil
        })

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)
      assert normalized.body == "Just plain text here."
      assert normalized.source == :email
    end

    test "normalizes html-only email (no text) by stripping tags" do
      parsed =
        parser_output(%{
          from: "carol@example.com",
          text: nil,
          html: "<html><body><p>Hello <strong>world</strong></p></body></html>"
        })

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)
      assert normalized.body =~ "Hello"
      assert normalized.body =~ "world"
      refute normalized.body =~ "<"
    end

    test "preserves message_id, in_reply_to, references from atom keys" do
      parsed =
        parser_output(%{
          text: "Reply body",
          message_id: "<threading-001@example.com>",
          in_reply_to: "<original-001@example.com>",
          references: "<original-001@example.com> <reply-001@example.com>",
          headers: %{
            "message-id" => "<threading-001@example.com>",
            "in-reply-to" => "<original-001@example.com>",
            "references" => "<original-001@example.com> <reply-001@example.com>"
          }
        })

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)
      assert normalized.message_id == "<threading-001@example.com>"
      assert normalized.in_reply_to == "<original-001@example.com>"
      assert normalized.references == "<original-001@example.com> <reply-001@example.com>"
    end

    test "preserves headers map" do
      custom_headers = %{
        "message-id" => "<hdr-001@example.com>",
        "X-Priority" => "1",
        "X-Custom-Tag" => "vip-customer"
      }

      parsed = parser_output(%{headers: custom_headers})

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)
      assert normalized.headers == custom_headers
    end

    test "defaults subject to (no subject) when missing" do
      parsed = parser_output(%{subject: nil, text: "Body without subject"})

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)
      assert normalized.subject == "(no subject)"
    end

    test "defaults body to empty string when both text and html are nil" do
      parsed = parser_output(%{text: nil, html: nil})

      assert {:ok, normalized} = EmailAdapter.normalize(parsed)
      assert normalized.body == ""
    end
  end
end

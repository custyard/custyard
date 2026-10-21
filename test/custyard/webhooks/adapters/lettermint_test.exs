defmodule Custyard.Webhooks.Adapters.LettermintTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Lettermint

  describe "source_name/0" do
    test "returns :lettermint" do
      assert Lettermint.source_name() == :lettermint
    end
  end

  describe "verify_signature/3" do
    test "returns :ok for a current signed timestamp and raw body" do
      payload = ~s({"from":"alice@example.com"})
      secret = "test-secret-key"
      timestamp = to_string(System.system_time(:second))

      digest =
        :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> payload)
        |> Base.encode16(case: :lower)

      signature = "t=#{timestamp},v1=#{digest}"

      assert :ok = Lettermint.verify_signature(payload, signature, secret)
    end

    test "rejects the former body-only signature" do
      payload = ~s({"from":"alice@example.com"})
      secret = "test-secret-key"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      assert {:error, "invalid signature format"} =
               Lettermint.verify_signature(payload, signature, secret)
    end

    test "returns error for invalid signature" do
      assert {:error, "invalid signature format"} =
               Lettermint.verify_signature("payload", "bad-sig", "secret")
    end

    test "returns error for missing signature" do
      assert {:error, "missing signature header"} =
               Lettermint.verify_signature("payload", nil, "secret")
    end

    test "returns error for no secret configured" do
      assert {:error, "no secret configured"} = Lettermint.verify_signature("payload", "sig", nil)
    end

    test "rejects stale signed timestamps" do
      payload = ~s({"from":"alice@example.com"})
      timestamp = to_string(System.system_time(:second) - 601)

      digest =
        :crypto.mac(:hmac, :sha256, "secret", timestamp <> "." <> payload)
        |> Base.encode16(case: :lower)

      assert {:error, "stale timestamp" <> _} =
               Lettermint.verify_signature(payload, "t=#{timestamp},v1=#{digest}", "secret")
    end
  end

  describe "normalize/1" do
    test "normalizes standard email payload" do
      params = %{
        "from" => "alice@example.com",
        "to" => "support@custyard.test",
        "subject" => "Need help",
        "text" => "Hello there",
        "headers" => %{
          "message-id" => "abc123@example.com",
          "in-reply-to" => "prev@example.com"
        }
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.from == "alice@example.com"
      assert normalized.to == "support@custyard.test"
      assert normalized.subject == "Need help"
      assert normalized.body == "Hello there"
      assert normalized.message_id == "abc123@example.com"
      assert normalized.in_reply_to == "prev@example.com"
      assert normalized.source == :lettermint
    end

    test "falls back to sender/recipient fields" do
      params = %{"sender" => "bob@example.com", "recipient" => "inbox@test.com"}

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.from == "bob@example.com"
      assert normalized.to == "inbox@test.com"
    end

    test "defaults subject to (no subject)" do
      params = %{"from" => "alice@example.com", "text" => "body"}

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.subject == "(no subject)"
    end

    test "strips HTML when no text body" do
      params = %{
        "from" => "alice@example.com",
        "html" => "<p>Hello <strong>world</strong></p>"
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.body =~ "Hello"
      assert normalized.body =~ "world"
      refute normalized.body =~ "<"
    end

    test "handles case-insensitive headers" do
      params = %{
        "from" => "alice@example.com",
        "headers" => %{"Message-Id" => "abc@example.com"}
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.message_id == "abc@example.com"
    end
  end

  describe "normalize/1 with the enveloped event" do
    defp inbound_envelope(data_overrides \\ %{}) do
      %{
        "id" => "e3d4f5a6-b7c8-9012-d3e4-f5a6b7c89012",
        "event" => "message.inbound",
        "timestamp" => "2025-10-02T14:30:00.000Z",
        "data" =>
          Map.merge(
            %{
              "route" => "support-inbox",
              "message_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
              "envelope" => %{
                "remote_ip" => "203.0.113.42",
                "remote_hostname" => "mail.example.com",
                "helo" => "smtp.example.com",
                "mail_from" => "customer@example.com"
              },
              "from" => %{
                "email" => "customer@example.com",
                "name" => "John Doe",
                "subaddress" => nil
              },
              "to" => [%{"email" => "support@acme.com", "name" => nil, "subaddress" => nil}],
              "cc" => [%{"email" => "boss@example.com", "name" => "Boss", "subaddress" => nil}],
              "recipient" => "support@acme.com",
              "subaddress" => nil,
              "reply_to" => "customer@example.com",
              "subject" => "Question about my order",
              "date" => "2025-10-02T14:30:00.000Z",
              "body" => %{
                "text" => "Hi, where is my order?",
                "html" => "<p>Hi, where is my order?</p>"
              },
              "tag" => nil,
              "tags" => [],
              "headers" => [
                %{"name" => "Message-ID", "value" => "<abc123@mail.example.com>"},
                %{"name" => "In-Reply-To", "value" => "<prev@mail.example.com>"},
                %{
                  "name" => "references",
                  "value" => "<root@mail.example.com> <prev@mail.example.com>"
                },
                %{"name" => "X-Mailer", "value" => "Apple Mail"},
                %{"name" => "X-Mailer", "value" => "second occurrence is ignored"},
                %{"name" => "Broken", "value" => 42},
                "not a header"
              ],
              "authentication_results" => %{
                "authserv_id" => "lettermint.mx",
                "header" => "lettermint.mx; dkim=pass; spf=pass; dmarc=pass",
                "dkim" => %{"result" => "pass", "domain" => "example.com", "selector" => "mail"},
                "dmarc" => %{"result" => "pass", "domain" => "example.com", "policy" => "none"},
                "spf" => %{"result" => "softfail", "domain" => "example.com"}
              },
              "attachments" => [
                %{
                  "filename" => "receipt.pdf",
                  "content_type" => "application/pdf",
                  "size" => 45_678,
                  "content_id" => nil,
                  "content" => "JVBERi0..."
                }
              ],
              "raw" => %{"url" => "https://storage.lettermint.co/signed", "expires_at" => "later"},
              "is_spam" => false,
              "spam_score" => 1.2,
              "spam_symbols" => [%{"name" => "DKIM_VALID", "score" => -0.1}]
            },
            data_overrides
          )
      }
    end

    test "formats from with the display name and routes to the envelope recipient" do
      assert {:ok, normalized} = Lettermint.normalize(inbound_envelope())
      assert normalized.from == "John Doe <customer@example.com>"
      assert normalized.to == "support@acme.com"
      assert normalized.subject == "Question about my order"
      assert normalized.source == :lettermint
    end

    test "uses the bare email when the display name is blank or unsafe" do
      for name <- [nil, "", "   ", "Evil <x@y>", "Line\nBreak", "Tab\there"] do
        envelope =
          inbound_envelope(%{"from" => %{"email" => "customer@example.com", "name" => name}})

        assert {:ok, normalized} = Lettermint.normalize(envelope)
        assert normalized.from == "customer@example.com", "name #{inspect(name)} was kept"
      end
    end

    test "falls back to the first to[] address when recipient is absent" do
      envelope = inbound_envelope(%{"recipient" => nil})

      assert {:ok, normalized} = Lettermint.normalize(envelope)
      assert normalized.to == "support@acme.com"
    end

    test "takes the body from text" do
      assert {:ok, normalized} = Lettermint.normalize(inbound_envelope())
      assert normalized.body == "Hi, where is my order?"
    end

    test "falls back to stripped html when text is null" do
      envelope =
        inbound_envelope(%{"body" => %{"text" => nil, "html" => "<p>Hello <b>world</b></p>"}})

      assert {:ok, normalized} = Lettermint.normalize(envelope)
      assert normalized.body == "Hello world"
    end

    test "an empty body is tolerated" do
      envelope = inbound_envelope(%{"body" => %{"text" => nil, "html" => nil}})

      assert {:ok, normalized} = Lettermint.normalize(envelope)
      assert normalized.body == ""
    end

    test "converts the header list to a map and resolves threading headers case-insensitively" do
      assert {:ok, normalized} = Lettermint.normalize(inbound_envelope())
      assert normalized.message_id == "<abc123@mail.example.com>"
      assert normalized.in_reply_to == "<prev@mail.example.com>"
      assert normalized.references == "<root@mail.example.com> <prev@mail.example.com>"

      assert normalized.headers == %{
               "Message-ID" => "<abc123@mail.example.com>",
               "In-Reply-To" => "<prev@mail.example.com>",
               "references" => "<root@mail.example.com> <prev@mail.example.com>",
               "X-Mailer" => "Apple Mail"
             }
    end

    test "metadata carries the compact summary and nothing private" do
      assert {:ok, %{metadata: metadata}} = Lettermint.normalize(inbound_envelope())

      assert metadata == %{
               provider_delivery_id: "e3d4f5a6-b7c8-9012-d3e4-f5a6b7c89012",
               lettermint_message_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479",
               recipient: "support@acme.com",
               subaddress: nil,
               reply_to: "customer@example.com",
               cc: ["boss@example.com"],
               authentication: %{
                 dkim: "pass",
                 dkim_domain: "example.com",
                 spf: "softfail",
                 dmarc: "pass"
               },
               is_spam: false,
               spam_score: 1.2
             }

      for key <- [:raw, :attachments, :spam_symbols, :envelope, :remote_ip, :headers] do
        refute Map.has_key?(metadata, key)
      end

      refute inspect(metadata) =~ "203.0.113.42"
      refute inspect(metadata) =~ "storage.lettermint.co"
      refute inspect(metadata) =~ "JVBERi0"
    end

    test "metadata tolerates missing optional sections" do
      envelope =
        inbound_envelope(%{
          "authentication_results" => nil,
          "cc" => nil,
          "is_spam" => "false",
          "spam_score" => "1.2"
        })

      assert {:ok, %{metadata: metadata}} = Lettermint.normalize(envelope)
      assert metadata.cc == []
      assert metadata.authentication == %{dkim: nil, dkim_domain: nil, spf: nil, dmarc: nil}
      assert metadata.is_spam == nil
      assert metadata.spam_score == nil
    end

    test "a non-inbound event is bypassed as ignored" do
      envelope = inbound_envelope() |> Map.put("event", "message.delivered")

      assert {:bypass, %{type: "ignored_event", event: "message.delivered"}} =
               Lettermint.normalize(envelope)
    end

    test "the legacy flat payload still normalizes with empty metadata" do
      params = %{
        "from" => "alice@example.com",
        "to" => "support@custyard.test",
        "subject" => "Flat",
        "text" => "Hello",
        "headers" => %{"message-id" => "flat@example.com"}
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.from == "alice@example.com"
      assert normalized.message_id == "flat@example.com"
      assert normalized.metadata == %{}
    end
  end
end

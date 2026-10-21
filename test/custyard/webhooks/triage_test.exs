defmodule Custyard.Webhooks.TriageTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Webhooks.Triage

  setup do
    org = insert_organization()
    route = insert_inbound_route(organization_id: org.id, source: :lettermint)
    %{org: org, route: route}
  end

  defp normalized(overrides \\ %{}) do
    Map.merge(
      %{
        from: "Alice <alice@customer.example.com>",
        to: "support@acme.example.com",
        subject: "Hello",
        body: "Plain customer mail",
        message_id: "<cust-#{System.unique_integer([:positive])}@customer.example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :lettermint,
        metadata: %{
          recipient: "support@acme.example.com",
          mail_from: "alice@customer.example.com",
          authentication: %{
            dkim: "pass",
            dkim_domain: "customer.example.com",
            spf: "pass",
            dmarc: "pass"
          },
          is_spam: false,
          spam_score: 0.5
        }
      },
      overrides
    )
  end

  defp put_metadata(normalized, overrides),
    do: Map.update!(normalized, :metadata, &Map.merge(&1, overrides))

  describe "customer mail" do
    test "ordinary mail is customer", %{route: route} do
      assert {:customer, nil} = Triage.classify(normalized(), route, nil)
    end

    test "a payload without metadata is customer", %{route: route} do
      payload = normalized() |> Map.put(:metadata, %{})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "a sender that cannot be parsed is customer", %{route: route} do
      assert {:customer, nil} = Triage.classify(normalized(%{from: nil}), route, nil)
    end
  end

  describe "own outbound echo" do
    test "matches an operator message by raw Message-ID in the organization", %{
      org: org,
      route: route
    } do
      conversation = insert_conversation(organization_id: org.id)

      reply =
        insert_message(
          conversation_id: conversation.id,
          source: :operator,
          message_id: "<reply-1.c1@custyard.local>"
        )

      assert {:own_echo, echoed} =
               Triage.classify(
                 normalized(%{message_id: "<reply-1.c1@custyard.local>"}),
                 route,
                 nil
               )

      assert echoed.id == reply.id
    end

    test "matches after whitespace normalization of the Message-ID", %{org: org, route: route} do
      conversation = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        message_id: "<reply-2.c1@custyard.local>"
      )

      assert {:own_echo, _} =
               Triage.classify(
                 normalized(%{message_id: "  <reply-2.c1@custyard.local>  "}),
                 route,
                 nil
               )
    end

    test "an operator message in another organization is not an echo", %{route: route} do
      other = insert_conversation()

      insert_message(
        conversation_id: other.id,
        source: :operator,
        message_id: "<reply-3.c9@custyard.local>"
      )

      assert {:customer, nil} =
               Triage.classify(
                 normalized(%{message_id: "<reply-3.c9@custyard.local>"}),
                 route,
                 nil
               )
    end

    test "a customer message with the same Message-ID is not an echo", %{org: org, route: route} do
      conversation = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        message_id: "<dup-4@customer.example.com>"
      )

      assert {:customer, nil} =
               Triage.classify(
                 normalized(%{message_id: "<dup-4@customer.example.com>"}),
                 route,
                 nil
               )
    end
  end

  describe "provider verification" do
    test "Gmail confirmation carries the code from the subject and the google.com link", %{
      route: route
    } do
      payload =
        normalized(%{
          from: "Gmail Team <forwarding-noreply@google.com>",
          subject:
            "(#123456789) Gmail Forwarding Confirmation - Receive Mail from ops@acme.example.com",
          body: """
          ops@acme.example.com has requested to automatically forward mail to your email address.
          Confirmation code: 123456789
          Click the link below: https://mail-settings.google.com/mail/vf-%5BANGjdJ8%5D-abc. Thanks.
          Unrelated: https://evil.example.com/phish
          """
        })

      assert {:verification, capture} = Triage.classify(payload, route, nil)
      assert capture.provider == :google
      assert capture.code == "123456789"
      assert capture.link == "https://mail-settings.google.com/mail/vf-%5BANGjdJ8%5D-abc"
    end

    test "any @google.com sender counts when the subject is a forwarding confirmation", %{
      route: route
    } do
      payload =
        normalized(%{
          from: "noreply-forwarding@google.com",
          subject: "Gmail Forwarding Confirmation",
          body: "No link here"
        })

      assert {:verification, %{provider: :google, code: nil, link: nil}} =
               Triage.classify(payload, route, nil)
    end

    test "an unrelated @google.com sender is customer mail", %{route: route} do
      payload = normalized(%{from: "someone@google.com", subject: "Partnership"})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "Proton notification carries the first proton.me link and no code", %{route: route} do
      payload =
        normalized(%{
          from: "Proton <no-reply@notify.proton.me>",
          subject: "Confirm your forwarding address (#999)",
          body: "Confirm at https://account.proton.me/forward/confirm?token=abc then done."
        })

      assert {:verification, capture} = Triage.classify(payload, route, nil)
      assert capture.provider == :proton
      assert capture.code == nil
      assert capture.link == "https://account.proton.me/forward/confirm?token=abc"
    end

    test "a link on a lookalike host is ignored", %{route: route} do
      payload =
        normalized(%{
          from: "forwarding-noreply@google.com",
          subject: "(#1) Gmail Forwarding Confirmation",
          body: "https://google.com.evil.example/x and http://mail.google.com/insecure"
        })

      assert {:verification, %{link: nil}} = Triage.classify(payload, route, nil)
    end

    test "the sender list is configurable", %{route: route} do
      Application.put_env(:custyard, :forwarding_verification_senders, %{
        google: ["Forwarding@Example.test"],
        proton: []
      })

      on_exit(fn -> Application.delete_env(:custyard, :forwarding_verification_senders) end)

      payload = normalized(%{from: "forwarding@example.test", subject: "x"})
      assert {:verification, %{provider: :google}} = Triage.classify(payload, route, nil)

      payload = normalized(%{from: "no-reply@notify.proton.me", subject: "x"})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "verification beats auto-response signals", %{route: route} do
      payload =
        normalized(%{
          from: "forwarding-noreply@google.com",
          subject: "(#42) Gmail Forwarding Confirmation",
          headers: %{"Auto-Submitted" => "auto-generated"}
        })

      assert {:verification, _} = Triage.classify(payload, route, nil)
    end
  end

  describe "auto-response" do
    test "Auto-Submitted other than no", %{route: route} do
      payload = normalized(%{headers: %{"auto-submitted" => "auto-replied"}})
      assert {:auto_response, :auto_submitted} = Triage.classify(payload, route, nil)
    end

    test "Auto-Submitted: no is not an auto-response", %{route: route} do
      payload = normalized(%{headers: %{"Auto-Submitted" => "No"}})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "bulk, junk, list and auto_reply precedence", %{route: route} do
      for value <- ["bulk", "Junk", "list", "auto_reply"] do
        payload = normalized(%{headers: %{"Precedence" => value}})
        assert {:auto_response, :precedence} = Triage.classify(payload, route, nil)
      end

      payload = normalized(%{headers: %{"Precedence" => "first-class"}})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "X-Autoreply, X-Autorespond and X-Auto-Response-Suppress", %{route: route} do
      for name <- ["X-Autoreply", "x-autorespond", "X-Auto-Response-Suppress"] do
        payload = normalized(%{headers: %{name => "yes"}})
        assert {:auto_response, :auto_reply_header} = Triage.classify(payload, route, nil)
      end
    end

    test "an empty envelope sender is a bounce", %{route: route} do
      payload = normalized() |> put_metadata(%{mail_from: ""})
      assert {:auto_response, :empty_envelope_sender} = Triage.classify(payload, route, nil)

      payload = normalized() |> put_metadata(%{mail_from: nil})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "auto-response beats suspect", %{route: route} do
      payload =
        normalized(%{headers: %{"Precedence" => "bulk"}}) |> put_metadata(%{is_spam: true})

      assert {:auto_response, :precedence} = Triage.classify(payload, route, nil)
    end

    test "own echo beats auto-response", %{org: org, route: route} do
      conversation = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        message_id: "<echo-5.c1@custyard.local>"
      )

      payload =
        normalized(%{
          message_id: "<echo-5.c1@custyard.local>",
          headers: %{"Auto-Submitted" => "auto-generated"}
        })

      assert {:own_echo, _} = Triage.classify(payload, route, nil)
    end
  end

  describe "suspect" do
    test "spam-flagged mail from an unknown sender", %{route: route} do
      payload = normalized() |> put_metadata(%{is_spam: true})
      assert {:suspect, :spam_flagged} = Triage.classify(payload, route, nil)
    end

    test "DKIM and DMARC both failing from an unknown sender", %{route: route} do
      payload =
        normalized()
        |> put_metadata(%{
          authentication: %{dkim: "fail", dkim_domain: nil, spf: "pass", dmarc: "FAIL"}
        })

      assert {:suspect, :unauthenticated} = Triage.classify(payload, route, nil)
    end

    test "DKIM fail alone, or SPF fail, is not suspect", %{route: route} do
      payload =
        normalized()
        |> put_metadata(%{
          authentication: %{dkim: "fail", dkim_domain: nil, spf: "fail", dmarc: "pass"}
        })

      assert {:customer, nil} = Triage.classify(payload, route, nil)

      payload =
        normalized()
        |> put_metadata(%{
          authentication: %{dkim: "pass", dkim_domain: nil, spf: "fail", dmarc: "fail"}
        })

      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "an existing contact in the organization is exempt", %{org: org, route: route} do
      insert_contact(organization_id: org.id, email: "alice@customer.example.com")

      payload = normalized() |> put_metadata(%{is_spam: true})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "a contact in another organization does not exempt the sender", %{route: route} do
      insert_contact(email: "alice@customer.example.com")

      payload = normalized() |> put_metadata(%{is_spam: true})
      assert {:suspect, :spam_flagged} = Triage.classify(payload, route, nil)
    end
  end
end

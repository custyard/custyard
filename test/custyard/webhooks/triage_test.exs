defmodule Custyard.Webhooks.TriageTest do
  # Not async: "the sender list is configurable" swaps the application-wide
  # :forwarding_verification_senders, which would race any other module
  # classifying a Proton or Gmail notice at the same time.
  use Custyard.DataCase, async: false

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
    test "matches a staff message by raw Message-ID in the organization", %{
      org: org,
      route: route
    } do
      thread = insert_thread(organization_id: org.id)

      reply =
        insert_message(
          thread_id: thread.id,
          source: :staff,
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
      thread = insert_thread(organization_id: org.id)

      insert_message(
        thread_id: thread.id,
        source: :staff,
        message_id: "<reply-2.c1@custyard.local>"
      )

      assert {:own_echo, _} =
               Triage.classify(
                 normalized(%{message_id: "  <reply-2.c1@custyard.local>  "}),
                 route,
                 nil
               )
    end

    test "a staff message in another tenant is not an echo", %{route: route} do
      other_tenant = insert_tenant()
      other = insert_thread(tenant_id: other_tenant.id)

      insert_message(
        thread_id: other.id,
        source: :staff,
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
      thread = insert_thread(organization_id: org.id)

      insert_message(
        thread_id: thread.id,
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

  describe "staff-sent capture and manual forward" do
    setup %{org: org} do
      staff =
        insert_staff_account(
          role: "admin",
          organization_id: org.id,
          email: "me@acme.example.com"
        )

      conv = insert_thread(organization_id: org.id)
      insert_message(thread_id: conv.id, message_id: "<orig@customer.example.com>")
      %{staff: staff, conv: conv}
    end

    defp staff_mail(overrides) do
      normalized(
        Map.merge(
          %{
            from: "Me <me@acme.example.com>",
            metadata: %{
              recipient: "support@acme.example.com",
              mail_from: "me@acme.example.com",
              authentication: %{
                dkim: "pass",
                dkim_domain: "acme.example.com",
                spf: "pass",
                dmarc: "pass"
              },
              is_spam: false,
              spam_score: 0.1
            }
          },
          overrides
        )
      )
    end

    @forward_body """
    ---------- Forwarded message ---------
    From: Alice <alice@customer.example.com>
    Date: Mon
    Subject: Login broken

    I cannot log in.
    """

    test "an authenticated staff reply into a known thread is staff_sent", %{
      route: route,
      staff: staff,
      conv: conv
    } do
      payload =
        staff_mail(%{in_reply_to: "<orig@customer.example.com>", body: "Fixed it for you."})

      assert {:staff_sent,
              %{
                thread: %{id: conv_id},
                staff: %{id: op_id},
                email: "me@acme.example.com"
              }} =
               Triage.classify(payload, route, nil)

      assert conv_id == conv.id
      assert op_id == staff.id
    end

    test "an authenticated staff forward with no thread is staff_forward", %{route: route} do
      payload = staff_mail(%{subject: "Fwd: Login broken", body: @forward_body})

      assert {:staff_forward,
              %{original: %{email: "alice@customer.example.com", subject: "Login broken"}}} =
               Triage.classify(payload, route, nil)
    end

    test "a forwarded block without a Fwd: subject still unwraps", %{route: route} do
      payload = staff_mail(%{subject: "see below", body: @forward_body})
      assert {:staff_forward, _info} = Triage.classify(payload, route, nil)
    end

    test "a forward that cannot be unwrapped is customer mail", %{route: route} do
      payload = staff_mail(%{subject: "Fwd: something", body: "no block here"})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "without an aligned DKIM pass the staff address is just a sender", %{route: route} do
      for auth <- [
            %{dkim: "fail", dkim_domain: "acme.example.com", dmarc: "pass"},
            %{dkim: "pass", dkim_domain: "evil.example", dmarc: "pass"},
            %{dkim: nil, dkim_domain: nil, dmarc: nil}
          ] do
        payload =
          staff_mail(%{in_reply_to: "<orig@customer.example.com>"})
          |> put_metadata(%{authentication: auth})

        assert {:customer, nil} = Triage.classify(payload, route, nil), inspect(auth)
      end
    end

    test "a subdomain signature is aligned", %{route: route} do
      payload =
        staff_mail(%{in_reply_to: "<orig@customer.example.com>"})
        |> put_metadata(%{
          authentication: %{dkim: "pass", dkim_domain: "mail.acme.example.com", dmarc: "pass"}
        })

      assert {:staff_sent, _info} = Triage.classify(payload, route, nil)
    end

    test "staff of another tenant is not staff-owned here", %{route: route} do
      other = insert_tenant()

      insert_staff_account(
        role: "admin",
        tenant_id: other.id,
        email: "them@acme.example.com"
      )

      payload =
        staff_mail(%{
          from: "them@acme.example.com",
          in_reply_to: "<orig@customer.example.com>"
        })

      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "an instance admin is not tenant staff", %{route: route} do
      %Custyard.InstanceAdmin{}
      |> Custyard.InstanceAdmin.changeset(%{email: "root@acme.example.com"})
      |> Repo.insert!()

      payload =
        staff_mail(%{
          from: "root@acme.example.com",
          in_reply_to: "<orig@customer.example.com>"
        })

      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end

    test "the channel's public address counts as staff-owned with no account", %{route: route} do
      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "support@acme.example.com",
          state: :active
        )

      payload =
        staff_mail(%{
          from: "Acme Support <support@acme.example.com>",
          in_reply_to: "<orig@customer.example.com>"
        })

      assert {:staff_sent, %{staff: nil, email: "support@acme.example.com"}} =
               Triage.classify(payload, route, channel)

      assert {:customer, nil} = Triage.classify(payload, route, nil)
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

    test "current Proton forwarding mail selects the acceptance action over branding links", %{
      route: route
    } do
      payload =
        normalized(%{
          from: "Proton <no-reply@mail.proton.me>",
          subject: "Confirm forwarding request",
          body: "Proton https://proton.me/mail",
          headers: %{"Precedence" => "bulk"}
        })
        |> put_metadata(%{
          links: [
            "https://proton.me/mail",
            "https://account.proton.me/email-forwarding/reject#decline-token",
            "https://account.proton.me/email-forwarding/accept#confirmation-token",
            "https://proton.me/"
          ]
        })

      assert {:verification, %{provider: :proton, code: nil, link: link}} =
               Triage.classify(payload, route, nil)

      assert link == "https://account.proton.me/email-forwarding/accept#confirmation-token"
    end

    test "ordinary Proton notification mail is not a forwarding confirmation", %{route: route} do
      payload =
        normalized(%{
          from: "Proton <no-reply@mail.proton.me>",
          subject: "You have new messages",
          headers: %{"Precedence" => "bulk"}
        })

      assert {:auto_response, :precedence} = Triage.classify(payload, route, nil)
    end

    test "Proton branding and lookalike acceptance links are not confirmation actions", %{
      route: route
    } do
      payload =
        normalized(%{
          from: "Proton <no-reply@mail.proton.me>",
          subject: "Confirm forwarding request",
          body: """
          https://proton.me/mail
          https://account.proton.me.evil.example/email-forwarding/accept#token
          https://account.proton.me/email-forwarding/reject#token
          """
        })

      assert {:verification, %{link: nil}} = Triage.classify(payload, route, nil)
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

    test "an HTML-only notice keeps the link the adapter lifted from its anchors", %{
      route: route
    } do
      # strip_html/1 removes the href, so the text body has no URL; the
      # adapter puts anchor hrefs in metadata.links for exactly this case.
      payload =
        normalized(%{
          from: "Proton <no-reply@notify.proton.me>",
          subject: "Confirm forwarding",
          body: "Confirm forwarding Click here to confirm"
        })
        |> put_metadata(%{
          links: [
            "https://tracking.example.net/open",
            "https://account.proton.me/forward/confirm?token=xyz&amp;x=1"
          ]
        })

      assert {:verification, capture} = Triage.classify(payload, route, nil)
      assert capture.link == "https://account.proton.me/forward/confirm?token=xyz&amp;x=1"
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

    test "X-Autoreply and X-Autorespond", %{route: route} do
      for name <- ["X-Autoreply", "x-autorespond"] do
        payload = normalized(%{headers: %{name => "yes"}})
        assert {:auto_response, :auto_reply_header} = Triage.classify(payload, route, nil)
      end
    end

    test "X-Auto-Response-Suppress is a request to the recipient, not an auto-response marker",
         %{route: route} do
      payload = normalized(%{headers: %{"X-Auto-Response-Suppress" => "All"}})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
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
      thread = insert_thread(organization_id: org.id)

      insert_message(
        thread_id: thread.id,
        source: :staff,
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

    test "a contact in another tenant does not exempt the sender", %{route: route} do
      other_tenant = insert_tenant()
      other_org = insert_organization(tenant_id: other_tenant.id)
      insert_contact(organization_id: other_org.id, email: "alice@customer.example.com")

      payload = normalized() |> put_metadata(%{is_spam: true})
      assert {:suspect, :spam_flagged} = Triage.classify(payload, route, nil)
    end

    test "a contact whose only threads are suspect does not exempt the sender", %{
      org: org,
      route: route
    } do
      # Sender matching created this contact from the first suspect delivery.
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example.com")
      insert_thread(organization_id: org.id, contact_id: contact.id, suspect: true)

      payload = normalized() |> put_metadata(%{is_spam: true})
      assert {:suspect, :spam_flagged} = Triage.classify(payload, route, nil)
    end

    test "one accepted thread makes the sender known", %{org: org, route: route} do
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example.com")
      insert_thread(organization_id: org.id, contact_id: contact.id, suspect: true)

      cleared =
        insert_thread(organization_id: org.id, contact_id: contact.id, suspect: true)

      # The staff dismissing the flag is what whitelists the sender.
      {:ok, _} = Custyard.Threads.set_suspect(cleared, false)

      payload = normalized() |> put_metadata(%{is_spam: true})
      assert {:customer, nil} = Triage.classify(payload, route, nil)
    end
  end
end

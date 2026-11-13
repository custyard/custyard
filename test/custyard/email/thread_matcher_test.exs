defmodule Custyard.Email.ThreadMatcherTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.Email.ThreadMatcher

  test "headers are matched only in the receiving tenant, including duplicate message ids" do
    a = insert_organization()
    b = insert_organization(tenant_id: insert_tenant().id)
    thread_a = insert_thread(organization_id: a.id)
    thread_b = insert_thread(organization_id: b.id)
    insert_message(thread_id: thread_a.id, message_id: "shared@example.com")
    insert_message(thread_id: thread_b.id, message_id: "shared@example.com")
    parsed = %{from: "alice@example.com", in_reply_to: "shared@example.com", references: nil}
    assert {:ok, %{id: id_a}} = ThreadMatcher.find_in_tenant(parsed, a.tenant_id)
    assert {:ok, %{id: id_b}} = ThreadMatcher.find_in_tenant(parsed, b.tenant_id)
    assert id_a == thread_a.id
    assert id_b == thread_b.id
    refute id_a == id_b
  end

  test "In-Reply-To precedes References and missing headers do not match" do
    org = insert_organization()
    a = insert_thread(organization_id: org.id)
    b = insert_thread(organization_id: org.id)
    insert_message(thread_id: a.id, message_id: "a@example.com")
    insert_message(thread_id: b.id, message_id: "b@example.com")

    assert {:ok, %{id: id}} =
             ThreadMatcher.find_in_tenant(
               %{in_reply_to: "a@example.com", references: "b@example.com"},
               org.tenant_id
             )

    assert id == a.id
    assert :not_found = ThreadMatcher.find_in_tenant(%{}, org.tenant_id)
  end

  test "subject fallback requires reply prefix, same customer and a participating sender" do
    org = insert_organization()
    contact = insert_contact(organization_id: org.id, email: "alice@example.com")

    thread =
      insert_thread(organization_id: org.id, contact_id: contact.id, subject: "Onboarding")

    assert {:ok, %{id: id}} =
             ThreadMatcher.find_by_subject(
               %{subject: "Re: Onboarding", from: contact.email},
               org.id,
               org.tenant_id
             )

    assert id == thread.id

    assert :not_found =
             ThreadMatcher.find_by_subject(
               %{subject: "Onboarding", from: contact.email},
               org.id,
               org.tenant_id
             )

    assert :not_found =
             ThreadMatcher.find_by_subject(
               %{subject: "Re: Onboarding", from: "stranger@example.com"},
               org.id,
               org.tenant_id
             )
  end

  test "ambiguous references do not select an arbitrary customer" do
    org = insert_organization()
    a = insert_thread(organization_id: org.id)
    b = insert_thread(organization_id: org.id)
    insert_message(thread_id: a.id, message_id: "a@example.com")
    insert_message(thread_id: b.id, message_id: "b@example.com")

    assert :ambiguous =
             ThreadMatcher.find_in_tenant(
               %{references: "a@example.com b@example.com"},
               org.tenant_id
             )
  end

  describe "find_for_sent_reply/3" do
    setup do
      org = insert_organization()
      alice = insert_contact(organization_id: org.id, email: "alice@customer.example")
      %{org: org, alice: alice}
    end

    defp ago(seconds),
      do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

    test "matches the recipient's thread once reply and forward prefixes are removed", %{
      org: org,
      alice: alice
    } do
      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: alice.id,
          subject: "Fwd:  Login broken"
        )

      for subject <- ["Re: Login broken", "AW: Fwd: RE: login   BROKEN", "Login broken"] do
        assert {:ok, %{id: id}} =
                 ThreadMatcher.find_for_sent_reply([alice.email], subject, org.tenant_id)

        assert id == thread.id
      end
    end

    test "one recipient with two subjects gets the thread with the same subject", %{
      org: org,
      alice: alice
    } do
      login =
        insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Login broken")

      insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Invoice 42")

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Login broken", org.tenant_id)

      assert id == login.id

      assert :not_found =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Refund", org.tenant_id)
    end

    test "two recipients with the same subject never share a thread", %{org: org, alice: alice} do
      bob = insert_contact(organization_id: org.id, email: "bob@customer.example")
      for_alice = insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Hello")
      for_bob = insert_thread(organization_id: org.id, contact_id: bob.id, subject: "Hello")

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Hello", org.tenant_id)

      assert id == for_alice.id

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([bob.email], "Re: Hello", org.tenant_id)

      assert id == for_bob.id

      assert :not_found =
               ThreadMatcher.find_for_sent_reply(
                 ["carol@customer.example"],
                 "Re: Hello",
                 org.tenant_id
               )
    end

    test "the first recipient with a matching thread decides", %{org: org, alice: alice} do
      bob = insert_contact(organization_id: org.id, email: "bob@customer.example")

      insert_thread(
        organization_id: org.id,
        contact_id: alice.id,
        subject: "Hello",
        state: :resolved
      )

      for_bob = insert_thread(organization_id: org.id, contact_id: bob.id, subject: "Hello")

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply(
                 ["nobody@customer.example", bob.email, alice.email],
                 "Re: Hello",
                 org.tenant_id
               )

      assert id == for_bob.id
    end

    test "an unresolved thread comes before a resolved one", %{org: org, alice: alice} do
      attrs = [organization_id: org.id, contact_id: alice.id, subject: "Hello"]
      # The resolved thread is the more recently active of the two.
      resolved = insert_thread(attrs ++ [state: :resolved, last_customer_action_at: ago(60)])
      waiting = insert_thread(attrs ++ [state: :waiting, last_customer_action_at: ago(7200)])

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Hello", org.tenant_id)

      assert id == waiting.id

      Repo.delete!(waiting)

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Hello", org.tenant_id)

      assert id == resolved.id
    end

    test "among unresolved threads the most recently active one wins", %{org: org, alice: alice} do
      attrs = [organization_id: org.id, contact_id: alice.id, subject: "Hello"]
      # The oldest row, so the order of creation does not decide.
      latest = insert_thread(attrs ++ [state: :active, last_staff_action_at: ago(600)])
      insert_thread(attrs ++ [state: :waiting, last_customer_action_at: ago(7200)])

      # Nobody has acted on this one: it counts from when it was created.
      insert_thread(attrs ++ [state: :new])
      |> Ecto.Changeset.change(inserted_at: ago(86_400))
      |> Repo.update!()

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Hello", org.tenant_id)

      assert id == latest.id

      untouched = insert_thread(attrs ++ [state: :new])

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Hello", org.tenant_id)

      assert id == untouched.id
    end

    test "a public-intake thread matches on its prospect address until it is revoked", %{org: org} do
      thread =
        insert_thread(source: :public_intake, tenant_id: org.tenant_id, subject: "Pricing")

      prospect = insert_prospect(thread_id: thread.id, email: "pat@prospect.example")

      assert {:ok, %{id: id}} =
               ThreadMatcher.find_for_sent_reply(
                 ["pat@prospect.example"],
                 "Re: Pricing",
                 org.tenant_id
               )

      assert id == thread.id

      prospect |> Ecto.Changeset.change(revoked_at: ago(0)) |> Repo.update!()

      assert :not_found =
               ThreadMatcher.find_for_sent_reply(
                 ["pat@prospect.example"],
                 "Re: Pricing",
                 org.tenant_id
               )
    end

    test "another tenant's thread, a chat thread, no recipients and no subject do not match", %{
      org: org,
      alice: alice
    } do
      other = insert_organization(tenant_id: insert_tenant().id)
      theirs = insert_contact(organization_id: other.id, email: alice.email)
      insert_thread(organization_id: other.id, contact_id: theirs.id, subject: "Hello")

      insert_thread(
        organization_id: org.id,
        contact_id: alice.id,
        subject: "Hello",
        source: :slack
      )

      insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Re:")

      assert :not_found =
               ThreadMatcher.find_for_sent_reply([alice.email], "Re: Hello", org.tenant_id)

      assert :not_found = ThreadMatcher.find_for_sent_reply([], "Re: Hello", other.tenant_id)

      assert :not_found =
               ThreadMatcher.find_for_sent_reply([alice.email], "Fwd: Re:", org.tenant_id)

      assert :not_found = ThreadMatcher.find_for_sent_reply([alice.email], nil, org.tenant_id)
    end
  end
end

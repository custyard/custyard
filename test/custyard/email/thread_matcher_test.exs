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
end

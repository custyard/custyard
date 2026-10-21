defmodule Custyard.Webhooks.Purposes.EnrichmentTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Conversation, Repo}
  alias Custyard.Webhooks.Purposes.Enrichment

  defp normalized(body) do
    %{
      from: "alice@customer.example",
      subject: "Hilfe",
      body: body,
      message_id: "<m@customer.example>",
      in_reply_to: nil,
      references: nil,
      headers: %{},
      source: :lettermint,
      metadata: %{}
    }
  end

  test "detects the language of the first message and keeps it afterwards" do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id)

    german = "Hallo, ich habe ein Problem mit meinem Konto und die Rechnung wird nicht angezeigt."
    insert_message(conversation_id: conv.id, source: :email, body: german)
    assert :ok = Enrichment.process(conv, normalized(german), %{})
    assert Repo.get!(Conversation, conv.id).language == "de"

    english =
      "Hello again, this is the same customer and I have one more question for you please."

    insert_message(conversation_id: conv.id, source: :email, body: english)
    assert :ok = Enrichment.process(conv, normalized(english), %{})
    assert Repo.get!(Conversation, conv.id).language == "de"
  end

  test "out-of-order enrichment chooses the earliest detectable customer message" do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id)
    english = "Hello, I have a problem with my account and the invoice is not showing up."
    german = "Hallo, ich habe ein Problem mit meinem Konto und die Rechnung wird nicht angezeigt."
    insert_message(conversation_id: conv.id, source: :email, body: "thx")

    insert_message(
      conversation_id: conv.id,
      source: :email,
      body: english,
      triage_class: :suspect
    )

    insert_message(conversation_id: conv.id, source: :email, body: german)
    insert_message(conversation_id: conv.id, source: :email, body: english)

    assert :ok = Enrichment.process(conv, normalized(english), %{})
    assert Repo.get!(Conversation, conv.id).language == "de"
  end

  test "leaves the language unset when the text is too short to tell" do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id)

    assert :ok = Enrichment.process(conv, normalized("thx"), %{})
    assert Repo.get!(Conversation, conv.id).language == nil
  end

  test "external priority still applies alongside language" do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id, urgency: :normal)

    payload =
      normalized("Hello, I have a problem with my account and the invoice is not showing up.")
      |> Map.put(:metadata, %{external_priority: "urgent"})

    insert_message(conversation_id: conv.id, source: :email, body: payload.body)
    assert :ok = Enrichment.process(conv, payload, %{})
    reloaded = Repo.get!(Conversation, conv.id)
    assert reloaded.urgency == :urgent
    assert reloaded.language == "en"
  end
end

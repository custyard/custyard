defmodule Custyard.Email.LettermintThreadingTest.ApiClient do
  @behaviour Swoosh.ApiClient

  def post(_url, _headers, body, _email) do
    payload = Jason.decode!(body)
    send(Application.fetch_env!(:custyard, :lettermint_threading_test_owner), {:payload, payload})
    {:ok, 202, [], ~s({"message_id":"provider-reply","status":"pending"})}
  end
end

defmodule Custyard.Email.LettermintThreadingTest do
  use Custyard.DataCase, async: false
  import Custyard.Factory

  alias Custyard.{Conversations, Message, Repo}
  alias Custyard.Email.{Outbound, ThreadMatcher}
  alias Custyard.Webhooks.Dispatcher

  setup do
    original_mailer = Application.get_env(:custyard, Custyard.Mailer)
    original_api = Application.get_env(:swoosh, :api_client)

    Application.put_env(:custyard, Custyard.Mailer,
      adapter: Swoosh.Adapters.Lettermint,
      api_token: "test-project-token"
    )

    Application.put_env(:swoosh, :api_client, __MODULE__.ApiClient)
    Application.put_env(:custyard, :lettermint_threading_test_owner, self())

    on_exit(fn ->
      Application.put_env(:custyard, Custyard.Mailer, original_mailer)
      Application.put_env(:swoosh, :api_client, original_api)
      Application.delete_env(:custyard, :lettermint_threading_test_owner)
    end)

    org = insert_organization()
    contact = insert_contact(organization_id: org.id, email: "alice@customer.example")
    route = insert_inbound_route(organization_id: org.id)

    channel =
      insert_inbound_channel(
        inbound_route_id: route.id,
        organization_id: org.id,
        public_address: "support@service.example",
        archive_copy: true,
        state: :active
      )

    conversation =
      insert_conversation(
        organization_id: org.id,
        contact_id: contact.id,
        inbound_channel_id: channel.id,
        source: :lettermint
      )

    insert_message(
      conversation_id: conversation.id,
      source: :email,
      sender_email: contact.email,
      triage_class: :customer,
      message_id: "<customer-original@customer.example>"
    )

    {:ok, reply} = Conversations.send_reply(conversation, "A support answer")
    assert {:ok, sent} = Outbound.deliver(reply)
    assert_receive {:payload, payload}

    %{
      org: org,
      contact: contact,
      route: route,
      channel: channel,
      conversation: conversation,
      sent: sent,
      payload: payload
    }
  end

  test "the serialized request preserves the stored ID so forwarded archives are ignored", c do
    # Lettermint replaces the submitted ID unless this control header is set.
    assert c.payload["headers"]["X-LM-Preserve-Message-ID"] == "true"
    delivered_id = c.payload["headers"]["Message-ID"]
    assert delivered_id == c.sent.message_id
    before_count = Repo.aggregate(Message, :count)

    assert {:ignored, :own_echo} =
             Dispatcher.dispatch(c.route, normalized(c.channel.public_address, delivered_id),
               channel: c.channel
             )

    assert Repo.aggregate(Message, :count) == before_count
    assert {:ok, c.contact.email} == Outbound.reply_recipient(c.conversation)
  end

  test "a customer reply referencing only the delivered ID keeps its thread", c do
    assert c.payload["headers"]["X-LM-Preserve-Message-ID"] == "true"

    incoming =
      normalized(c.contact.email, "<customer-return@customer.example>")
      |> Map.put(:in_reply_to, c.payload["headers"]["Message-ID"])

    assert {:ok, matched} = ThreadMatcher.find_in_tenant(incoming, c.conversation.tenant_id)
    assert matched.id == c.conversation.id
    assert matched.organization_id == c.org.id
  end

  defp normalized(sender, message_id) do
    %{
      from: sender,
      to: "support@service.example",
      subject: "Re: A support question",
      body: "A forwarded copy",
      message_id: message_id,
      in_reply_to: nil,
      references: nil,
      headers: %{},
      source: :lettermint,
      metadata: %{to: ["support@service.example"], cc: []}
    }
  end
end

defmodule Custyard.Email.ReplyRecipients do
  @moduledoc """
  Resolves the customer side of an email reply for both the composer and sender.

  The latest eligible customer message supplies Reply-To or From. A conversation's
  original contact remains its customer relationship, not a permanent delivery
  target after another participant joins the thread.
  """

  import Ecto.Query

  alias Custyard.{Conversations, EmailAddress, InboundChannels, Message, Repo}
  alias Custyard.Email.SenderMatcher

  @email_sources [:email, :lettermint]

  def resolve(conversation, opts \\ []) do
    with {:ok, recipient} <- recipient(conversation) do
      {:ok, %{to: recipient, cc: cc(conversation, recipient, opts)}}
    end
  end

  def recipient(conversation) do
    conversation = Repo.preload(conversation, [:contact, :prospect])

    case Conversations.reply_channel(conversation) do
      {:contact, address} ->
        {:ok, latest_recipient(conversation) || address}

      {:prospect, address} ->
        if conversation.prospect.notify_on_reply,
          do: {:ok, address},
          else: {:error, :no_consent}

      :none ->
        {:error, :no_recipient_email}
    end
  end

  def default_cc(conversation, opts \\ []) do
    case resolve(conversation, opts) do
      {:ok, %{cc: addresses}} -> addresses
      {:error, _} -> []
    end
  end

  defp latest_recipient(%{source: source} = conversation)
       when source in [:email, :lettermint, :portal, :public_intake] do
    case latest_message(conversation.id) do
      nil -> nil
      message -> valid_address(message.reply_to) || valid_address(message.sender_email)
    end
  end

  defp latest_recipient(_conversation), do: nil

  defp cc(%{source: source} = conversation, recipient, opts) when source in @email_sources do
    case latest_message(conversation.id) do
      nil ->
        []

      message ->
        excluded = own_addresses(conversation, opts) |> MapSet.put(recipient)

        excluded =
          if valid_address(message.reply_to),
            do: MapSet.put(excluded, valid_address(message.sender_email)),
            else: excluded

        ((message.cc_addresses || []) ++ (message.to_addresses || []) ++ [message.sender_email])
        |> Enum.map(&valid_address/1)
        |> Enum.reject(&(is_nil(&1) or MapSet.member?(excluded, &1)))
        |> Enum.uniq()
    end
  end

  defp cc(_conversation, _recipient, _opts), do: []

  defp latest_message(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.source == :email and m.is_internal_note == false and is_nil(m.deleted_at),
      where: is_nil(m.triage_class) or m.triage_class in [:customer, :staff_forward],
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp own_addresses(conversation, opts) do
    channel =
      if conversation.inbound_channel_id,
        do: InboundChannels.get_channel(conversation.inbound_channel_id)

    previous_ingress =
      if channel && channel.previous_ingress_token && channel.inbound_route do
        "#{channel.ingress_local}+#{channel.previous_ingress_token}@#{channel.inbound_route.lettermint_route_domain}"
      end

    [
      Conversations.reply_identity(conversation, opts).address,
      Keyword.get(opts, :staff_email),
      channel && channel.public_address,
      channel && InboundChannels.ingress_address(channel),
      channel && channel.inbound_route && channel.inbound_route.from_address,
      previous_ingress
    ]
    |> Enum.map(&valid_address/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp valid_address(value) do
    case SenderMatcher.extract_email(value) do
      address when is_binary(address) -> if EmailAddress.valid?(address), do: address
      _ -> nil
    end
  end
end

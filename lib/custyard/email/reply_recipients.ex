defmodule Custyard.Email.ReplyRecipients do
  @moduledoc """
  Resolves the customer side of an email reply for both the composer and sender.

  The latest eligible customer message supplies Reply-To or From. A thread's
  original contact remains its customer relationship, not a permanent delivery
  target after another participant joins the thread.
  """

  import Ecto.Query

  alias Custyard.{Threads, EmailAddress, InboundChannels, Message, Repo}
  alias Custyard.Email.SenderMatcher

  @email_sources [:email, :lettermint]

  def resolve(thread, opts \\ []) do
    with {:ok, recipient} <- recipient(thread) do
      {:ok, %{to: recipient, cc: cc(thread, recipient, opts)}}
    end
  end

  def recipient(thread) do
    thread = Repo.preload(thread, [:contact, :prospect])

    case Threads.reply_channel(thread) do
      {:contact, address} ->
        {:ok, latest_recipient(thread) || address}

      {:prospect, address} ->
        if thread.prospect.notify_on_reply,
          do: {:ok, address},
          else: {:error, :no_consent}

      :none ->
        {:error, :no_recipient_email}
    end
  end

  def default_cc(thread, opts \\ []) do
    case resolve(thread, opts) do
      {:ok, %{cc: addresses}} -> addresses
      {:error, _} -> []
    end
  end

  defp latest_recipient(%{source: source} = thread)
       when source in [:email, :lettermint, :portal, :public_intake] do
    case latest_message(thread.id) do
      nil -> nil
      message -> valid_address(message.reply_to) || valid_address(message.sender_email)
    end
  end

  defp latest_recipient(_thread), do: nil

  defp cc(%{source: source} = thread, recipient, opts) when source in @email_sources do
    case latest_message(thread.id) do
      nil ->
        []

      message ->
        excluded = own_addresses(thread, opts) |> MapSet.put(recipient)

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

  defp cc(_thread, _recipient, _opts), do: []

  defp latest_message(thread_id) do
    from(m in Message,
      where: m.thread_id == ^thread_id,
      where: m.source == :email and m.is_internal_note == false and is_nil(m.deleted_at),
      where: is_nil(m.triage_class) or m.triage_class in [:customer, :staff_forward],
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp own_addresses(thread, opts) do
    channel =
      if thread.inbound_channel_id,
        do: InboundChannels.get_channel(thread.inbound_channel_id)

    previous_ingress =
      if channel && channel.previous_ingress_token && channel.inbound_route do
        "#{channel.ingress_local}+#{channel.previous_ingress_token}@#{channel.inbound_route.lettermint_route_domain}"
      end

    [
      Threads.reply_identity(thread, opts).address,
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

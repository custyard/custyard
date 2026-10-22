defmodule Custyard.MessageRecipientStatus do
  @moduledoc """
  The latest delivery status of one recipient of an outbound message
  (spec-conversation-loop, "Delivery Tracking").

  Lettermint reports delivery per recipient. `Custyard.Email.DeliveryStatus`
  keeps one row per address a message was sent to and applies the rank and
  terminal rules to each row on its own, ordered by the provider's event
  time. The message's own `delivery_status` follows its `to` recipient; a
  `cc` or `other` (archive copy) recipient's failure is shown next to the
  message instead of replacing its indicator.

  `address` is stored lower-cased and trimmed, as the provider named it.
  `role` is fixed when the first event for the address arrives, from the
  recipient lists the message recorded at send time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:to, :cc, :other]
  @statuses [:sent, :delivered, :failed, :bounced, :suppressed]
  @failures [:bounced, :suppressed, :failed]

  schema "message_recipient_statuses" do
    field :address, :string
    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: @statuses
    field :status_at, :utc_datetime

    belongs_to :message, Custyard.Message

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def statuses, do: @statuses

  @doc "Whether the recipient's status is a delivery failure."
  def failed?(%__MODULE__{status: status}), do: status in @failures

  @doc false
  def changeset(recipient_status, attrs) do
    recipient_status
    |> cast(attrs, [:message_id, :address, :role, :status, :status_at])
    |> validate_required([:message_id, :address, :role, :status, :status_at])
    |> validate_length(:address, max: 255)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:message_id, :address],
      name: :message_recipient_statuses_message_id_address_index
    )
  end
end

defmodule Custyard.StaffMessageDraft do
  @moduledoc "Private, short-lived reply and internal-note drafts owned by one staff member."
  use Ecto.Schema
  import Ecto.Changeset

  schema "staff_message_drafts" do
    belongs_to :staff_account, Custyard.StaffAccount
    belongs_to :thread, Custyard.Thread
    belongs_to :reply_channel, Custyard.InboundChannel
    field :reply_text, :string, default: ""
    field :note_text, :string, default: ""
    field :reply_cc, :string, default: ""
    field :reviewed_activity_id, :integer, default: 0
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:reply_text, :note_text, :reply_cc, :reply_channel_id, :reviewed_activity_id],
      empty_values: []
    )
    |> validate_length(:reply_text, max: 100_000)
    |> validate_length(:note_text, max: 100_000)
    |> validate_length(:reply_cc, max: 5_000)
    |> validate_number(:reviewed_activity_id, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:reply_channel_id)
    |> unique_constraint([:staff_account_id, :thread_id])
  end
end

defmodule Custyard.MessageAttachment do
  @moduledoc """
  A file attached to an inbound message (spec-inbound-channels D9).

  The provider hands Custyard a signed URL per attachment; the fetcher
  downloads within the channel's per-message cap, stores the content in the
  database (`Custyard.Files`) and records what it learned here. The signed
  URL is never stored. `filename` is display data only: the content is keyed
  by `sha256` within the tenant, so a hostile filename never names anything
  in storage. `sniffed_type` is derived from the bytes and is what the
  download endpoint serves; the declared `content_type` is kept for the staff.

  States: `fetched` (content stored), `skipped` (listed but deliberately not
  fetched: over the cap, suspect mail, fetching disabled) and `failed`
  (fetch attempted and lost).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states [:pending, :fetched, :skipped, :failed]
  @skip_reasons ~w(over_limit suspect disabled fetch_failed too_large no_url invalid_descriptor)

  schema "message_attachments" do
    field :position, :integer
    field :descriptor_hash, :string
    field :batch_processing_token, :string
    field :batch_processing_expires_at, :utc_datetime
    field :processing_token, :string
    field :processing_expires_at, :utc_datetime
    field :filename, :string
    field :content_type, :string
    field :sniffed_type, :string
    field :size, :integer
    field :sha256, :string

    # The table keeps a storage_path column from when content was a file on disk; nothing reads it.

    field :content_id, :string
    field :state, Ecto.Enum, values: @states
    field :skip_reason, :string
    # Fetch completion and malware verdict are separate: a scanner outage must
    # neither acknowledge an unsafe file as clean nor reject the email itself.
    field :scan_status, Ecto.Enum,
      values: [:pending, :clean, :infected, :error],
      default: :pending

    field :scanned_at, :utc_datetime
    field :scan_token, :string

    belongs_to :tenant, Custyard.Tenant
    belongs_to :message, Custyard.Message

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def skip_reasons, do: @skip_reasons

  @doc false
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :tenant_id,
      :position,
      :descriptor_hash,
      :batch_processing_token,
      :batch_processing_expires_at,
      :processing_token,
      :processing_expires_at,
      :filename,
      :content_type,
      :sniffed_type,
      :size,
      :sha256,
      :content_id,
      :state,
      :skip_reason,
      :message_id
    ])
    |> update_change(:filename, &clean_filename/1)
    |> validate_required([:tenant_id, :state, :message_id])
    |> validate_length(:filename, max: 255)
    |> validate_length(:content_type, max: 255)
    |> validate_length(:sniffed_type, max: 255)
    |> validate_length(:content_id, max: 255)
    |> validate_inclusion(:skip_reason, @skip_reasons)
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_fetched()
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:message_id, :position])
  end

  # A fetched attachment must name its content: the hash is the key it is stored under.
  defp validate_fetched(changeset) do
    case get_field(changeset, :state) do
      :fetched -> validate_required(changeset, [:sha256, :size])
      _other -> changeset
    end
  end

  @doc """
  Display-safe filename: the basename only, control characters and quotes
  removed, truncated, `"attachment"` when nothing usable remains.
  """
  def clean_filename(nil), do: nil

  def clean_filename(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[\\\/]+/, "_")
      |> String.replace(~r/[\x00-\x1f\x7f"]/, "")
      |> String.trim()
      |> String.slice(0, 200)

    if cleaned in ["", ".", ".."], do: "attachment", else: cleaned
  end
end

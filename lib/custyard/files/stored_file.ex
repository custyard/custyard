defmodule Custyard.Files.StoredFile do
  @moduledoc """
  A file kept in the database: an inbound attachment or a tenant logo.

  The row describes the file; its content is in `Custyard.Files.Chunk` rows.
  `completed_at` is nil while the chunks are still being written, and only a
  row with `completed_at` set is the file for its `(tenant_id, kind, key)`.
  `Custyard.Files` is the only writer.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "stored_files" do
    field :kind, Ecto.Enum, values: [:attachment, :logo]
    field :key, :string
    field :sha256, :string
    field :size, :integer
    field :chunk_count, :integer
    field :completed_at, :utc_datetime

    belongs_to :tenant, Custyard.Tenant

    timestamps(type: :utc_datetime)
  end
end

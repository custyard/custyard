defmodule Custyard.Files.Chunk do
  @moduledoc """
  One piece of a stored file's content, `position` counting from 0.

  `data` is a BLOB of at most `Custyard.Files.chunk_bytes/0`. Select it only
  when the content is wanted.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "stored_file_chunks" do
    belongs_to :file, Custyard.Files.StoredFile, primary_key: true
    field :position, :integer, primary_key: true
    field :data, :binary
  end
end

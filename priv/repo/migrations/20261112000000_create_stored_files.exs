defmodule Custyard.Repo.Migrations.CreateStoredFiles do
  use Ecto.Migration

  # File content (attachments, logos) lives in the database, so a deployment
  # on a remote database needs no disk volume. libSQL servers refuse a single
  # blob of a few megabytes, so a file is a row plus its content in chunks.
  def change do
    create table(:stored_files) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :key, :string, null: false
      add :sha256, :string, null: false
      add :size, :integer, null: false
      add :chunk_count, :integer, null: false
      # Null while the chunks are still being written.
      add :completed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    # Only published files claim a key: an unfinished write must neither
    # block another writer nor be taken for the file.
    create unique_index(:stored_files, [:tenant_id, :kind, :key],
             where: "completed_at IS NOT NULL"
           )

    create index(:stored_files, [:kind, :key])

    create table(:stored_file_chunks, primary_key: false) do
      add :file_id, references(:stored_files, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :position, :integer, null: false, primary_key: true
      add :data, :binary, null: false
    end
  end
end

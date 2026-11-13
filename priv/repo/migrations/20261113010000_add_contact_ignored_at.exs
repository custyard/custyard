defmodule Custyard.Repo.Migrations.AddContactIgnoredAt do
  use Ecto.Migration

  # When staff chose to ignore this sender (Custyard.Threads.ignore_sender/2).
  # Null means the sender is not ignored. The queue reads it on the contact
  # join it already has, so it needs no index.
  def change do
    alter table(:contacts) do
      add :ignored_at, :utc_datetime
    end
  end
end

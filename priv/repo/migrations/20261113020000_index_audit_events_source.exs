defmodule Custyard.Repo.Migrations.IndexAuditEventsSource do
  use Ecto.Migration

  # Custyard.AuditLog.for_instance/2 lists the events instance admins caused,
  # which it finds by source. They are a handful among every tenant's mail
  # events; without this index each page reads the whole table, which a
  # remote database bills per row.
  def change do
    create index(:audit_events, [:source, :id])
  end
end

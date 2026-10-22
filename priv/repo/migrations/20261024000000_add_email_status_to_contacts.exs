defmodule Custyard.Repo.Migrations.AddEmailStatusToContacts do
  use Ecto.Migration

  # spec-conversation-loop, "Bounce and Suppression Handling": a bounce or
  # suppression of a reply to a contact's address flags the contact, and a
  # later delivery to the address clears the flag. The flag informs the
  # operator; it never blocks a send. email_status_at is the provider's event
  # time of the last change, so an older event arriving late cannot undo a
  # newer one.
  def change do
    alter table(:contacts) do
      add :email_status, :string, null: false, default: "valid"
      add :email_status_at, :utc_datetime
    end
  end
end

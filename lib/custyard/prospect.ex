defmodule Custyard.Prospect do
  @moduledoc """
  Anonymous prospect identity attached 1:1 to a public-intake thread.

  Created at intake time, the prospect row holds the hashed access token
  (the plaintext is shown to the submitter exactly once and never persisted),
  the captured email (write-once through the public flow), and the
  reply-notification consent flag (default off).

  The prospect persists unchanged through linking and conversion — it is the
  access credential holder and notification preference, not the identity. The
  "no reply channel" flag is derived from this record by
  `Custyard.Threads.reply_channel/1`, never stored.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Custyard.EmailAddress

  schema "prospects" do
    field :access_token_hash, :string
    field :email, :string
    field :notify_on_reply, :boolean, default: false
    field :email_captured_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :tenant, Custyard.Tenant
    belongs_to :thread, Custyard.Thread

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a prospect at intake time.

  Only the thread link and the token hash are settable here; email
  capture goes through `capture_email_changeset/2`.
  """
  def create_changeset(prospect, attrs) do
    prospect
    |> cast(attrs, [:tenant_id, :thread_id, :access_token_hash])
    |> put_tenant()
    |> validate_required([:tenant_id, :thread_id, :access_token_hash])
    |> unique_constraint(:thread_id)
    |> unique_constraint(:access_token_hash)
    |> foreign_key_constraint(:thread_id)
  end

  defp put_tenant(changeset) do
    case get_field(changeset, :thread_id) do
      id when is_integer(id) ->
        case Custyard.Repo.get(Custyard.Thread, id) do
          %{tenant_id: tenant_id} ->
            case get_field(changeset, :tenant_id) do
              nil -> put_change(changeset, :tenant_id, tenant_id)
              ^tenant_id -> changeset
              _ -> add_error(changeset, :tenant_id, "does not match the parent")
            end

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end

  @doc """
  Changeset for the public email-capture flow.

  Casts exactly `[:email, :email_captured_at, :notify_on_reply]`. The email is
  trimmed and downcased at write so storage and lookups never diverge on case.
  """
  def capture_email_changeset(prospect, attrs) do
    prospect
    |> cast(attrs, [:email, :email_captured_at, :notify_on_reply])
    |> update_change(:email, &EmailAddress.normalize/1)
    |> validate_required([:email, :email_captured_at])
    |> validate_length(:email, max: 320, message: "must be at most 320 characters")
    |> EmailAddress.validate_email(:email)
  end

  @doc """
  Changeset for toggling reply notifications.
  """
  def notification_changeset(prospect, notify?) do
    cast(prospect, %{notify_on_reply: notify?}, [:notify_on_reply])
  end

  @doc """
  Changeset for rotating the access token: stores the new hash, invalidating
  the previous token.
  """
  def rotate_token_changeset(prospect, new_hash) do
    prospect
    |> cast(%{access_token_hash: new_hash}, [:access_token_hash])
    |> validate_required([:access_token_hash])
    |> unique_constraint(:access_token_hash)
  end

  @doc """
  Changeset for revoking thread access.
  """
  def revoke_changeset(prospect, revoked_at) do
    cast(prospect, %{revoked_at: revoked_at}, [:revoked_at])
  end
end

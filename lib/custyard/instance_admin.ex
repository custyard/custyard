defmodule Custyard.InstanceAdmin do
  @moduledoc "Installation administration identity, with no tenant data access."
  use Ecto.Schema
  import Ecto.Changeset
  alias Custyard.Auth.Account

  schema "instance_admins" do
    field :email, :string
    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :login_token, :string, redact: true
    field :login_token_expires_at, :utc_datetime

    field :session_claim, :string,
      autogenerate: {Account, :generate_session_claim, []},
      redact: true

    timestamps(type: :utc_datetime)
  end

  def changeset(account, attrs),
    do:
      account
      |> Account.credentials_changeset(attrs, [:email, :password])
      |> unique_constraint(:email)
end

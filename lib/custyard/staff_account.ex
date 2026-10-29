defmodule Custyard.StaffAccount do
  @moduledoc "A tenant staff identity. Customer organizations never own staff."
  use Ecto.Schema
  import Ecto.Changeset
  alias Custyard.Auth.Account

  schema "staff_accounts" do
    field :email, :string
    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :login_token, :string, redact: true
    field :login_token_expires_at, :utc_datetime
    field :role, :string, default: "agent"

    field :session_claim, :string,
      autogenerate: {Account, :generate_session_claim, []},
      redact: true

    belongs_to :tenant, Custyard.Tenant
    timestamps(type: :utc_datetime)
  end

  def roles, do: ~w(admin agent)

  def changeset(account, attrs) do
    account
    |> Account.credentials_changeset(attrs, [:email, :password, :role, :tenant_id])
    |> validate_required([:tenant_id, :role])
    |> validate_inclusion(:role, roles())
    |> unique_constraint(:email, name: :staff_accounts_tenant_id_email_index)
    |> foreign_key_constraint(:tenant_id)
  end

  def role_changeset(account, attrs) do
    account
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, roles())
  end

  defdelegate normalize_email(email), to: Account
  defdelegate login_token_ttl_minutes(), to: Account
  defdelegate password_changeset(account, attrs), to: Account
  defdelegate login_token_changeset(account), to: Account
  defdelegate login_token_valid?(account), to: Account
  defdelegate clear_login_token_changeset(account), to: Account
  defdelegate verify_login_token(account, token), to: Account
  defdelegate verify_password(account, password), to: Account
  defdelegate session_claim(account), to: Account
  defdelegate session_claim_matches?(account, claim), to: Account
  defdelegate generate_session_claim(), to: Account

  def orphaned?(%__MODULE__{tenant_id: id, role: role})
      when is_integer(id) and role in ~w(admin agent) do
    false
  end

  def orphaned?(_), do: true

  def can_access_organization?(%__MODULE__{tenant_id: id}, organization_id) when is_integer(id) do
    case Custyard.Repo.get(Custyard.Organization, organization_id) do
      %{tenant_id: ^id} -> true
      _ -> false
    end
  end

  def can_access_organization?(_, _), do: false
end

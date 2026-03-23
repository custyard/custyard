defmodule Custyard.OperatorAccount do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operator_accounts" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(operator_account, attrs) do
    operator_account
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> unique_constraint(:email)
    |> hash_password()
  end

  @doc """
  Changeset for updating password only.
  """
  def password_changeset(operator_account, attrs) do
    operator_account
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        hash = Argon2.hash_pwd_salt(password)
        put_change(changeset, :password_hash, hash)
    end
  end

  @doc """
  Verifies a password against the stored hash.
  Uses constant-time comparison to prevent timing attacks.
  """
  def verify_password(%__MODULE__{password_hash: hash}, password) when is_binary(password) do
    Argon2.verify_pass(password, hash)
  end

  def verify_password(nil, _password) do
    # Prevent timing attacks by simulating password check for non-existent users
    Argon2.no_user_verify()
    false
  end

  def verify_password(_, _), do: false
end

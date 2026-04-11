defmodule Custyard.OperatorAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(super_admin admin agent)
  @login_token_ttl_minutes 15

  schema "operator_accounts" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :login_token, :string
    field :login_token_expires_at, :utc_datetime

    # Role for RBAC: super_admin can access all orgs, admin manages their org, agent handles support
    field :role, :string, default: "super_admin"

    # Nullable: super_admin operators have no organization_id (can access all)
    belongs_to :organization, Custyard.Organization

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid roles for operators.
  """
  def roles, do: @roles

  @doc """
  Returns the login token TTL in minutes.
  """
  def login_token_ttl_minutes, do: @login_token_ttl_minutes

  @doc false
  def changeset(operator_account, attrs) do
    operator_account
    |> cast(attrs, [:email, :password, :role, :organization_id])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/,
      message: "must be a valid email address"
    )
    |> maybe_validate_password()
    |> validate_inclusion(:role, @roles, message: "must be one of: #{Enum.join(@roles, ", ")}")
    |> validate_org_for_role()
    |> unique_constraint(:email)
    |> foreign_key_constraint(:organization_id)
    |> hash_password()
  end

  # Only validate password if one is provided
  defp maybe_validate_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      _ ->
        validate_length(changeset, :password,
          min: 8,
          max: 72,
          message: "must be between 8 and 72 characters"
        )
    end
  end

  @doc """
  Changeset for updating role and organization assignment.
  """
  def role_changeset(operator_account, attrs) do
    operator_account
    |> cast(attrs, [:role, :organization_id])
    |> validate_inclusion(:role, @roles, message: "must be one of: #{Enum.join(@roles, ", ")}")
    |> validate_org_for_role()
    |> foreign_key_constraint(:organization_id)
  end

  # Validates that non-super_admin roles have an organization_id
  defp validate_org_for_role(changeset) do
    role = get_field(changeset, :role)
    org_id = get_field(changeset, :organization_id)

    cond do
      role == "super_admin" && org_id != nil ->
        add_error(
          changeset,
          :organization_id,
          "super_admin operators cannot be scoped to an organization"
        )

      role in ["admin", "agent"] && is_nil(org_id) ->
        add_error(
          changeset,
          :organization_id,
          "#{role} operators must be assigned to an organization"
        )

      true ->
        changeset
    end
  end

  @doc """
  Changeset for updating password only.
  """
  def password_changeset(operator_account, attrs) do
    operator_account
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72, message: "must be between 8 and 72 characters")
    |> hash_password()
  end

  @doc """
  Generates a login token and sets its expiration.
  Returns a changeset with the token set.
  """
  def login_token_changeset(operator_account) do
    token = generate_login_token()
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@login_token_ttl_minutes * 60, :second)
      |> DateTime.truncate(:second)

    operator_account
    |> change(%{login_token: token, login_token_expires_at: expires_at})
  end

  @doc """
  Clears the login token after successful use.
  """
  def clear_login_token_changeset(operator_account) do
    operator_account
    |> change(%{login_token: nil, login_token_expires_at: nil})
  end

  @doc """
  Verifies a login token is valid and not expired.
  """
  def verify_login_token(
        %__MODULE__{login_token: token, login_token_expires_at: expires_at},
        provided_token
      )
      when is_binary(token) and is_binary(provided_token) do
    token_matches = Plug.Crypto.secure_compare(token, provided_token)
    not_expired = DateTime.compare(expires_at, DateTime.utc_now()) == :gt
    token_matches and not_expired
  end

  def verify_login_token(_, _), do: false

  defp generate_login_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
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

  # --- Authorization helpers ---

  @doc """
  Returns true if the operator is a super_admin (can access all organizations).
  """
  def super_admin?(%__MODULE__{role: "super_admin"}), do: true
  def super_admin?(_), do: false

  @doc """
  Returns true if the operator can access the given organization_id.
  Super admins can access all organizations; other roles can only access their own.
  """
  def can_access_organization?(%__MODULE__{role: "super_admin"}, _org_id), do: true

  def can_access_organization?(%__MODULE__{organization_id: op_org_id}, org_id)
      when is_integer(org_id) do
    op_org_id == org_id
  end

  def can_access_organization?(_, _), do: false

  @doc """
  Returns the organization_id this operator is scoped to, or nil for super_admins.
  Useful for filtering queries.
  """
  def scoped_organization_id(%__MODULE__{role: "super_admin"}), do: nil
  def scoped_organization_id(%__MODULE__{organization_id: org_id}), do: org_id
  def scoped_organization_id(_), do: nil
end

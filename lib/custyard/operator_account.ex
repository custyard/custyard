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

    # Random, set once on insert and never changed; see session_claim/1.
    field :session_claim, :string,
      autogenerate: {__MODULE__, :generate_session_claim, []},
      redact: true

    # Nullable: super_admin operators have no organization_id (can access all)
    belongs_to :organization, Custyard.Organization
    belongs_to :tenant, Custyard.Tenant

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

  @doc """
  Normalizes an email address to the form it is stored in: trimmed,
  lowercased with full Unicode case mapping, and in Unicode NFC.

  The login form looks accounts up by the normalized address, so every
  lookup and every write must go through this. NFC makes a precomposed
  "é" and "e" followed by a combining accent the same address.

  A binary that is not valid UTF-8 is returned unchanged; the changeset
  rejects it.
  """
  def normalize_email(email) when is_binary(email) do
    if String.valid?(email) do
      email |> String.trim() |> String.downcase() |> :unicode.characters_to_nfc_binary()
    else
      email
    end
  end

  def normalize_email(email), do: email

  @doc false
  def changeset(operator_account, attrs) do
    operator_account
    |> cast(attrs, [:email, :password, :role, :organization_id, :tenant_id])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_email_format()
    |> maybe_validate_password()
    |> validate_inclusion(:role, @roles, message: "must be one of: #{Enum.join(@roles, ", ")}")
    |> validate_org_for_role()
    |> unique_constraint(:email)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:organization_id)
    |> hash_password()
  end

  # The unicode regex treats non-ASCII whitespace (a no-break space pasted
  # into the address) as whitespace, but raises on invalid UTF-8, so
  # validity is checked first.
  defp validate_email_format(changeset) do
    case get_change(changeset, :email) do
      email when is_binary(email) ->
        if String.valid?(email) and Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/u, email),
          do: changeset,
          else: add_error(changeset, :email, "must be a valid email address", validation: :format)

      _ ->
        changeset
    end
  end

  # Only validate password if one is provided
  defp maybe_validate_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

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
    |> cast(attrs, [:role, :organization_id, :tenant_id])
    |> validate_inclusion(:role, @roles, message: "must be one of: #{Enum.join(@roles, ", ")}")
    |> validate_org_for_role()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:organization_id)
  end

  # Validates that non-super_admin roles have an organization_id
  defp validate_org_for_role(changeset) do
    role = get_field(changeset, :role)
    org_id = get_field(changeset, :organization_id)
    tenant_id = get_field(changeset, :tenant_id)

    cond do
      role == "super_admin" && tenant_id != nil ->
        add_error(
          changeset,
          :tenant_id,
          "instance administrators cannot be assigned to one tenant"
        )

      role == "super_admin" && org_id != nil ->
        add_error(
          changeset,
          :organization_id,
          "super_admin operators cannot be scoped to an organization"
        )

      role in ["admin", "agent"] && is_nil(org_id) && is_nil(tenant_id) ->
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
  Whether the operator holds a login token that has not expired yet.
  """
  def login_token_valid?(%__MODULE__{login_token: token} = operator) when is_binary(token),
    do: verify_login_token(operator, token)

  def login_token_valid?(_operator), do: false

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

    not_expired =
      if is_struct(expires_at, DateTime) do
        DateTime.compare(expires_at, DateTime.utc_now()) == :gt
      else
        false
      end

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

  def can_access_organization?(%__MODULE__{tenant_id: tenant_id}, org_id)
      when is_integer(tenant_id) and is_integer(org_id) do
    case Custyard.Repo.get(Custyard.Organization, org_id) do
      %{tenant_id: ^tenant_id} -> true
      _ -> false
    end
  end

  def can_access_organization?(%__MODULE__{organization_id: op_org_id}, org_id)
      when is_integer(org_id) do
    op_org_id == org_id
  end

  def can_access_organization?(_, _), do: false

  @doc """
  The value stored in the session at login next to the operator id: a
  random string generated when the account is created.

  The id alone does not identify an account over time. operator_accounts.id
  is INTEGER PRIMARY KEY without AUTOINCREMENT, so SQLite gives the next new
  row the id of a deleted highest-id row; a removed operator's still-valid
  cookie would then sign in as whoever was created next, even within the same
  second. A session counts only while the row with its id also has the claim
  it was issued for.
  """
  def session_claim(%__MODULE__{session_claim: claim}), do: claim

  @doc false
  def generate_session_claim, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  @doc """
  Whether `claim` (from the session) was issued for this account. A missing
  claim (a session from before claims existed) never matches.
  """
  def session_claim_matches?(%__MODULE__{session_claim: stored}, claim)
      when is_binary(stored) and is_binary(claim),
      do: Plug.Crypto.secure_compare(stored, claim)

  def session_claim_matches?(_operator, _claim), do: false

  @doc """
  Returns true for any account that is not a super_admin and has no
  organization: an admin or agent whose organization was deleted, or a row
  with an unexpected role (fails closed).

  Deleting an organization sets its operators' organization_id to NULL
  (ON DELETE SET NULL). `scoped_organization_id/1` then returns nil, which
  the queue and neglect views read as "all organizations", so such an
  account must never be authorized. Login, the `:require_operator` plug and
  the LiveView auth hooks all refuse it.
  """
  def orphaned?(%__MODULE__{role: role, organization_id: nil, tenant_id: nil})
      when role != "super_admin",
      do: true

  def orphaned?(_), do: false

  @doc """
  Returns the organization_id this operator is scoped to, or nil for super_admins.
  Useful for filtering queries. An `orphaned?/1` account also returns nil, so
  callers must have refused it first (the auth layer does).
  """
  def scoped_organization_id(%__MODULE__{role: "super_admin"}), do: nil
  def scoped_organization_id(%__MODULE__{tenant_id: id}) when is_integer(id), do: nil
  def scoped_organization_id(%__MODULE__{organization_id: org_id}), do: org_id
  def scoped_organization_id(_), do: nil
end

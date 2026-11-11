defmodule Custyard.Auth.Account do
  @moduledoc "Shared authentication primitives for staff and instance administrators."
  import Ecto.Changeset
  import Ecto.Query
  alias Custyard.Repo

  def login_token_ttl_minutes, do: 15
  def generate_session_claim, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  def normalize_email(email) when is_binary(email) do
    if String.valid?(email),
      do: email |> String.trim() |> String.downcase() |> :unicode.characters_to_nfc_binary(),
      else: email
  end

  def normalize_email(email), do: email

  def credentials_changeset(account, attrs, fields) do
    account
    |> cast(attrs, fields)
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_change(:email, fn :email, value ->
      if String.valid?(value) and Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/u, value),
        do: [],
        else: [email: "must be a valid email address"]
    end)
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
  end

  def password_changeset(account, attrs) do
    account
    |> cast(attrs, [:password])
    |> validate_required(:password)
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))
    end
  end

  def verify_password(%{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password),
      do: Argon2.verify_pass(password, hash)

  def verify_password(_, _) do
    Argon2.no_user_verify()
    false
  end

  def session_claim(%{session_claim: claim}), do: claim

  def session_claim_matches?(%{session_claim: stored}, claim)
      when is_binary(stored) and is_binary(claim) do
    Plug.Crypto.secure_compare(stored, claim)
  end

  def session_claim_matches?(_, _), do: false

  def login_token_changeset(account) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    expires =
      DateTime.utc_now()
      |> DateTime.add(login_token_ttl_minutes() * 60, :second)
      |> DateTime.truncate(:second)

    change(account, login_token: token, login_token_expires_at: expires)
  end

  def clear_login_token_changeset(account),
    do: change(account, login_token: nil, login_token_expires_at: nil)

  def login_token_valid?(%{login_token: token} = account) when is_binary(token),
    do: verify_login_token(account, token)

  def login_token_valid?(_), do: false

  def verify_login_token(
        %{login_token: token, login_token_expires_at: %DateTime{} = expires},
        provided
      )
      when is_binary(token) and is_binary(provided),
      do:
        Plug.Crypto.secure_compare(token, provided) and
          DateTime.compare(expires, DateTime.utc_now()) == :gt

  def verify_login_token(_, _), do: false

  def ensure_login_token(%schema{} = account) do
    if login_token_valid?(account) do
      account
    else
      %{changes: fresh} = login_token_changeset(account)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(a in schema,
        where: a.id == ^account.id,
        where:
          is_nil(a.login_token) or is_nil(a.login_token_expires_at) or
            a.login_token_expires_at <= ^now
      )
      |> Repo.update_all(set: Map.to_list(fresh))

      Repo.get!(schema, account.id)
    end
  end

  def consume_login_token(%schema{} = account, token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(a in schema,
        where: a.id == ^account.id and a.login_token == ^token,
        where: a.login_token_expires_at > ^now
      )
      |> Repo.update_all(set: [login_token: nil, login_token_expires_at: nil])

    if count == 1, do: :ok, else: {:error, :invalid}
  end

  def lock_current(%schema{id: id}) when is_integer(id) do
    case from(a in schema, where: a.id == ^id, update: [set: [updated_at: a.updated_at]])
         |> Repo.update_all([]) do
      {1, _} -> Repo.get!(schema, id)
      _ -> nil
    end
  end

  def lock_current(_), do: nil
end

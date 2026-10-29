defmodule Custyard.Organization do
  @moduledoc "A customer identity belonging to one tenant."
  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    belongs_to(:tenant, Custyard.Tenant)
    field(:public_id, :string, autogenerate: {Ecto.UUID, :generate, []})
    field(:identity_kind, Ecto.Enum, values: [:domain, :email, :manual], default: :manual)
    field(:identity_value, :string)
    field(:name, :string)
    field(:domain, :string)
    field(:tier, Ecto.Enum, values: [:enterprise, :standard, :basic], default: :standard)
    has_many(:contacts, Custyard.Contact)
    has_many(:threads, Custyard.Thread)
    has_many(:projects, Custyard.Project)
    has_many(:tasks, Custyard.WorkItem)
    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:tenant_id, :identity_kind, :identity_value, :name, :domain, :tier])
    |> update_change(:domain, &normalize/1)
    |> update_change(:identity_value, &normalize/1)
    |> put_identity()
    |> immutable_tenant()
    |> validate_identity()
    |> validate_required([:tenant_id, :name, :identity_kind, :identity_value])
    |> validate_length(:name, max: 255)
    |> validate_format(:domain, ~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}\z/)
    |> unique_constraint([:tenant_id, :identity_kind, :identity_value])
    |> unique_constraint([:tenant_id, :domain])
    |> foreign_key_constraint(:tenant_id)
  end

  defp validate_identity(changeset) do
    case {get_field(changeset, :identity_kind), get_field(changeset, :identity_value)} do
      {:email, value} ->
        if Custyard.EmailAddress.valid?(value),
          do: changeset,
          else: add_error(changeset, :identity_value, "must be a valid email address")

      {:domain, value} when is_binary(value) ->
        if Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}\z/, value),
          do: changeset,
          else: add_error(changeset, :identity_value, "must be a valid domain")

      _ ->
        changeset
    end
  end

  defp immutable_tenant(changeset) do
    if changeset.data.id && changed?(changeset, :tenant_id),
      do: add_error(changeset, :tenant_id, "cannot change a customer's tenant"),
      else: changeset
  end

  defp put_identity(changeset) do
    changeset =
      if get_field(changeset, :identity_kind) == :domain and changed?(changeset, :domain),
        do: put_change(changeset, :identity_value, get_field(changeset, :domain)),
        else: changeset

    case {get_field(changeset, :identity_kind), get_field(changeset, :identity_value)} do
      {:manual, nil} ->
        case get_field(changeset, :domain) do
          domain when is_binary(domain) and domain != "" ->
            changeset
            |> put_change(:identity_kind, :domain)
            |> put_change(:identity_value, domain)

          _ ->
            put_change(changeset, :identity_value, Ecto.UUID.generate())
        end

      {:domain, nil} ->
        put_change(changeset, :identity_value, get_field(changeset, :domain))

      _ ->
        changeset
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
end

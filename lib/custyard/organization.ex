defmodule Custyard.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    field :tenant_id, :id, default: 1
    belongs_to :tenant, Custyard.Tenant, define_field: false
    field :intake_key, :string
    field :name, :string
    field :domain, :string
    field :tier, Ecto.Enum, values: [:enterprise, :standard, :basic], default: :standard
    field :token, :string

    # Branding configuration for white-label portal
    field :logo_url, :string
    field :primary_color, :string
    field :secondary_color, :string

    # Custom domain for white-label portal (e.g., support.acme.com)
    field :custom_domain, :string

    # Lettermint project ID for route provisioning
    field :lettermint_project_id, :string

    has_many :contacts, Custyard.Contact
    has_many :conversations, Custyard.Conversation
    has_many :projects, Custyard.Project
    has_many :tasks, Custyard.Task
    has_many :operator_accounts, Custyard.OperatorAccount
    has_many :inbound_routes, Custyard.InboundRoute

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [
      :tenant_id,
      :intake_key,
      :name,
      :domain,
      :tier,
      :token,
      :logo_url,
      :primary_color,
      :secondary_color,
      :custom_domain,
      :lettermint_project_id
    ])
    |> maybe_generate_token()
    |> validate_required([:name, :token, :tenant_id])
    |> validate_token_strength()
    # Note: :tier uses Ecto.Enum which validates values automatically
    |> validate_format(:primary_color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a valid hex color (e.g., #1a2b3c)"
    )
    |> validate_format(:secondary_color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a valid hex color (e.g., #1a2b3c)"
    )
    |> unique_constraint(:token)
    |> unique_constraint(:domain, name: :organizations_tenant_id_domain_index)
    |> unique_constraint([:tenant_id, :intake_key])
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint(:custom_domain)
    |> validate_domain()
    |> update_change(:custom_domain, &normalize_custom_domain/1)
    |> validate_custom_domain()
    |> validate_logo_url()
  end

  # Validate and normalize the domain field
  # Empty strings are converted to nil to work with partial unique index
  defp validate_domain(changeset) do
    changeset = update_change(changeset, :domain, &normalize_custom_domain/1)

    case get_change(changeset, :domain) do
      nil ->
        changeset

      "" ->
        # Convert empty string to nil so partial unique index works correctly
        put_change(changeset, :domain, nil)

      # Allow _unmatched_ sentinel value for unknown sender organization
      "_unmatched_" ->
        changeset

      domain when is_binary(domain) ->
        # Basic domain validation - must look like a hostname
        if Regex.match?(
             ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i,
             domain
           ) do
          changeset
        else
          add_error(changeset, :domain, "must be a valid domain name")
        end
    end
  end

  # Hostnames are case-insensitive and browsers send them lowercase, while the
  # custom-domain lookup is an exact match; a domain saved as entered
  # ("Support.Acme.com") validated and verified but never resolved.
  defp normalize_custom_domain(domain) when is_binary(domain),
    do: domain |> String.trim() |> String.downcase()

  defp normalize_custom_domain(domain), do: domain

  defp validate_custom_domain(changeset) do
    case get_change(changeset, :custom_domain) do
      nil ->
        changeset

      domain when is_binary(domain) ->
        reserved? =
          domain == Custyard.Tenants.app_host() or
            not is_nil(Custyard.Tenants.resolve_host(domain))

        # Basic domain validation - must look like a hostname
        if not reserved? and
             Regex.match?(
               ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i,
               domain
             ) do
          changeset
        else
          add_error(changeset, :custom_domain, "must be a valid domain name")
        end
    end
  end

  @doc """
  Changeset for updating branding only.
  """
  def branding_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:logo_url, :primary_color, :secondary_color])
    |> validate_format(:primary_color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a valid hex color (e.g., #1a2b3c)"
    )
    |> validate_format(:secondary_color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a valid hex color (e.g., #1a2b3c)"
    )
    |> validate_logo_url()
  end

  # Upload-path discipline (uploads-only, traversal/null-byte rejection) is
  # shared with instance branding via Custyard.UploadPath.
  defp validate_logo_url(changeset) do
    case get_change(changeset, :logo_url) do
      nil ->
        changeset

      url when is_binary(url) ->
        case Custyard.UploadPath.validate(url) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, :logo_url, message)
        end
    end
  end

  defp maybe_generate_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, generate_token())
      _ -> changeset
    end
  end

  # Minimum token length: 32 chars provides ~192 bits of entropy (sufficient for auth)
  # Auto-generated tokens are 43 chars (256 bits). This allows manually set tokens
  # while still rejecting short/guessable values like "test" or "password".
  @min_token_length 32

  defp validate_token_strength(changeset) do
    case get_field(changeset, :token) do
      nil ->
        changeset

      token when is_binary(token) ->
        if String.length(token) >= @min_token_length do
          changeset
        else
          add_error(
            changeset,
            :token,
            "must be at least #{@min_token_length} characters for security"
          )
        end

      _ ->
        changeset
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end

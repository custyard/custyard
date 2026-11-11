defmodule Custyard.InboundRoute do
  @moduledoc "Tenant-owned inbound provider infrastructure. Customer routing hints live on channels."
  use Ecto.Schema
  import Ecto.Changeset

  # Sources must match adapter registry - see Custyard.Webhooks.Registry
  @sources [:lettermint, :zendesk, :intercom, :slack, :email]

  schema "inbound_routes" do
    field(:lettermint_route_id, :string)
    field(:lettermint_route_domain, :string)
    field(:lettermint_inbound_address, :string)
    field(:lettermint_custom_domain, :string)
    field(:lettermint_custom_domain_verified_at, :utc_datetime)
    field(:lettermint_webhook_id, :string)
    field(:webhook_secret_ciphertext, :string, redact: true)
    field(:webhook_verified_at, :utc_datetime)
    field(:callback_token, :string)
    # Source determines which webhook adapter processes requests to this route.
    # This is a security control - prevents attackers from selecting adapters.
    field(:source, Ecto.Enum, values: @sources, default: :lettermint)
    # The email address outbound replies should come from for this route.
    # Ensures customer replies flow back through the same webhook/route.
    field(:from_address, :string)

    belongs_to(:tenant, Custyard.Tenant)
    has_many(:webhooks, Custyard.InboundRouteWebhook)
    has_many(:channels, Custyard.InboundChannel)

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources

  @doc """
  The domain at which this route receives mail: the custom domain once
  Lettermint has verified it, otherwise the Lettermint catch-all domain.
  Returns nil when neither is known (non-Lettermint routes, or Lettermint
  routes created before the domain was captured).
  """
  def ingress_domain(%__MODULE__{
        lettermint_custom_domain: custom,
        lettermint_custom_domain_verified_at: %DateTime{}
      })
      when is_binary(custom) and custom != "",
      do: custom

  def ingress_domain(%__MODULE__{lettermint_route_domain: domain})
      when is_binary(domain) and domain != "",
      do: domain

  def ingress_domain(%__MODULE__{}), do: nil

  @doc """
  The Lettermint catch-all domain (`<id>.lettermint.app`), never the custom
  domain. Forwarding channel ingress addresses are built on it.
  """
  def forward_domain(%__MODULE__{lettermint_route_domain: domain})
      when is_binary(domain) and domain != "",
      do: domain

  def forward_domain(%__MODULE__{}), do: nil

  @doc "True once Lettermint has verified the route's custom domain MX record."
  def custom_domain_verified?(%__MODULE__{
        lettermint_custom_domain: custom,
        lettermint_custom_domain_verified_at: %DateTime{}
      })
      when is_binary(custom) and custom != "",
      do: true

  def custom_domain_verified?(%__MODULE__{}), do: false

  @doc """
  True when mail for `domain` reaches this route through its custom domain:
  an exact match, or a strict subdomain of a `*.` wildcard.
  """
  def custom_domain_covers?(%__MODULE__{lettermint_custom_domain: custom}, domain)
      when is_binary(custom) and custom != "" and is_binary(domain) do
    domain = String.downcase(domain)

    case custom do
      "*." <> parent -> String.ends_with?(domain, "." <> parent)
      exact -> domain == exact
    end
  end

  def custom_domain_covers?(%__MODULE__{}, _domain), do: false

  @doc false
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :lettermint_route_id,
      :lettermint_route_domain,
      :lettermint_inbound_address,
      :lettermint_custom_domain,
      :lettermint_custom_domain_verified_at,
      :callback_token,
      :source,
      :from_address,
      :tenant_id
    ])
    |> maybe_generate_callback_token()
    |> validate_required([:callback_token, :tenant_id])
    |> validate_token_strength()
    |> validate_format(:from_address, ~r/^[^\s]+@[^\s]+\.[^\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:lettermint_inbound_address, max: 255)
    |> validate_hostname(:lettermint_route_domain)
    |> validate_custom_domain()
    |> unique_constraint(:callback_token)
    |> foreign_key_constraint(:tenant_id)
  end

  # Same hostname rule as Custyard.Organization domains. Hostnames are
  # case-insensitive and the staff UI copies these verbatim, so store
  # them lowercased.
  @hostname_regex ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/

  defp validate_hostname(changeset, field) do
    changeset
    |> update_change(field, &normalize_hostname/1)
    |> validate_length(field, max: 255)
    |> validate_format(field, @hostname_regex, message: "must be a valid domain name")
  end

  # Lettermint refuses its own domains as custom inbound domains.
  @reserved_domains ["lettermint.app", "lettermint.mx", "inbound.lettermint.co"]

  defp validate_custom_domain(changeset) do
    changeset
    |> update_change(:lettermint_custom_domain, &normalize_hostname/1)
    |> validate_length(:lettermint_custom_domain, max: 255)
    |> validate_change(:lettermint_custom_domain, fn :lettermint_custom_domain, value ->
      host = String.replace_prefix(value, "*.", "")

      cond do
        not Regex.match?(@hostname_regex, host) ->
          [lettermint_custom_domain: "must be a domain name or a *. wildcard"]

        Enum.any?(@reserved_domains, &(host == &1 or String.ends_with?(host, "." <> &1))) ->
          [lettermint_custom_domain: "cannot be a Lettermint domain"]

        true ->
          []
      end
    end)
  end

  defp normalize_hostname(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      hostname -> hostname
    end
  end

  defp normalize_hostname(value), do: value

  defp maybe_generate_callback_token(changeset) do
    case get_field(changeset, :callback_token) do
      nil -> put_change(changeset, :callback_token, generate_token())
      _ -> changeset
    end
  end

  # Minimum token length: 32 chars provides ~192 bits of entropy (sufficient for auth)
  # Auto-generated tokens are 43 chars (256 bits). This rejects short/guessable values.
  @min_token_length 32

  defp validate_token_strength(changeset) do
    case get_field(changeset, :callback_token) do
      nil ->
        changeset

      token when is_binary(token) ->
        if String.length(token) >= @min_token_length do
          changeset
        else
          add_error(
            changeset,
            :callback_token,
            "must be at least #{@min_token_length} characters for security"
          )
        end

      _ ->
        changeset
    end
  end

  defp generate_token do
    # 32 bytes = 256 bits, matching Organization.generate_token
    # Callback tokens are exposed in external webhook URLs, so use full entropy
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end

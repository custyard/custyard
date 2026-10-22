defmodule Custyard.InboundChannel do
  @moduledoc """
  One public support address bound to an inbound route.

  A route is the Lettermint-backed ingress with organization and project
  scope; a channel is the operator-visible object on top of it: the public
  address customers write to (`support@companyname.com`), the ingress address
  the operator's mail service forwards to
  (`support+<token>@<route domain>`), the From identity for replies, and
  the lifecycle that tells the operator whether mail is flowing. See
  docs/design/spec-inbound-channels.md, decisions D1 to D4 and D7.

  ## States

      draft -> pending_verification -> awaiting_first_message -> active
                                   \\-> paused / revoked (from any state after draft)

  `Custyard.InboundChannels` owns every transition; this module only
  validates them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states [:draft, :pending_verification, :awaiting_first_message, :active, :paused, :revoked]
  @ingress_kinds [:forward, :mx, :imap]
  @providers [:proton, :google, :other]
  @reply_from_options [:public_address, :ingress_address]
  @sending_domain_statuses ~w(verified partially_verified pending_verification failed_verification not_found)

  # Lifecycle transitions the context may perform (D7). `paused` and
  # `revoked` are reachable from any state after draft; `paused` resumes to
  # the state it left, which the context passes explicitly.
  @transitions %{
    draft: [:pending_verification, :revoked],
    pending_verification: [:awaiting_first_message, :active, :paused, :revoked],
    awaiting_first_message: [:active, :paused, :revoked],
    active: [:paused, :revoked],
    paused: [:pending_verification, :awaiting_first_message, :active, :revoked],
    revoked: []
  }

  @token_length 20
  # Crockford base32, lowercase. Lowercase so case-insensitive matching by a
  # mail provider cannot weaken the token (D2).
  @token_alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @token_regex ~r/\A[0-9abcdefghjkmnpqrstvwxyz]{20}\z/
  # The ingress local part is derived from the public address and must stay a
  # conservative dot-atom so it never needs quoting in a forwarding rule. It
  # is capped so `local + "+" + token` stays within the 64-octet local-part
  # limit of RFC 5321: 43 + 1 + 20 = 64.
  @local_max_length 64 - 1 - @token_length
  @local_regex ~r/\A[a-z0-9](?:[a-z0-9._-]{0,42})\z/
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  schema "inbound_channels" do
    field :public_address, :string
    field :display_name, :string

    field :ingress_local, :string
    field :ingress_token, :string
    field :previous_ingress_token, :string
    field :previous_token_expires_at, :utc_datetime

    field :ingress_kind, Ecto.Enum, values: @ingress_kinds, default: :forward
    field :provider, Ecto.Enum, values: @providers

    field :state, Ecto.Enum, values: @states, default: :draft

    field :reply_from, Ecto.Enum, values: @reply_from_options, default: :public_address
    # D4: BCC every outbound reply to the public address so the operator's
    # mailbox keeps a copy. Off by default; the copy is forwarded back and
    # recognised by triage as an own echo.
    field :archive_copy, :boolean, default: false
    # D9: per-message attachment cap in megabytes; 0 disables fetching.
    field :attachment_limit_mb, :integer, default: 10
    field :sending_domain_status, :string
    field :sending_domain_checked_at, :utc_datetime

    field :verification_code, :string
    field :verification_link, :string
    field :verification_captured_at, :utc_datetime
    field :verification_expires_at, :utc_datetime

    field :verified_at, :utc_datetime
    field :last_received_at, :utc_datetime
    field :quiet_after_hours, :integer, default: 72
    field :quiet_notified_at, :utc_datetime
    field :paused_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :inbound_route, Custyard.InboundRoute
    belongs_to :organization, Custyard.Organization
    belongs_to :project, Custyard.Project

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def ingress_kinds, do: @ingress_kinds
  def providers, do: @providers
  def reply_from_options, do: @reply_from_options
  def sending_domain_statuses, do: @sending_domain_statuses
  def token_length, do: @token_length
  def transitions, do: @transitions

  @doc """
  Changeset for operator-editable attributes at creation and update.

  The ingress token is generated here when absent and is never cast from
  attrs; rotation goes through `rotate_token_changeset/2`.
  """
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :public_address,
      :display_name,
      :ingress_kind,
      :provider,
      :reply_from,
      :quiet_after_hours,
      :archive_copy,
      :attachment_limit_mb,
      :inbound_route_id,
      :organization_id,
      :project_id
    ])
    |> update_change(:public_address, &normalize_address/1)
    |> update_change(:display_name, &normalize_display_name/1)
    |> validate_required([:public_address, :ingress_kind, :inbound_route_id, :organization_id])
    |> validate_length(:public_address, max: 255)
    |> validate_format(:public_address, @email_regex, message: "must be a valid email address")
    |> validate_length(:display_name, max: 100)
    |> validate_number(:quiet_after_hours,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 720
    )
    |> validate_number(:attachment_limit_mb,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_kind_rules()
    |> put_ingress_local()
    |> maybe_generate_token()
    |> validate_format(:ingress_local, @local_regex,
      message: "cannot be derived from the address"
    )
    |> validate_format(:ingress_token, @token_regex)
    |> unique_constraint(:ingress_token)
    |> unique_constraint([:inbound_route_id, :public_address],
      error_key: :public_address,
      message: "is already a channel on this route"
    )
    |> foreign_key_constraint(:inbound_route_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Changeset for a lifecycle transition. Adds an error when the state machine
  does not allow it. `attrs` may carry the timestamps that accompany the
  transition (`verified_at`, `paused_at`, `revoked_at`).
  """
  def state_changeset(%__MODULE__{state: from} = channel, to, attrs \\ %{}) when to in @states do
    changeset =
      channel
      |> cast(Map.put(attrs, :state, to), [:state, :verified_at, :paused_at, :revoked_at])

    cond do
      from == to -> changeset
      to in Map.fetch!(@transitions, from) -> changeset
      true -> add_error(changeset, :state, "cannot transition from #{from} to #{to}")
    end
  end

  @doc "True when the state machine allows `from` -> `to`."
  def valid_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc """
  Changeset for the provider verification capture (D6, 24h TTL). `code` and
  `link` may each be nil when the provider sent only one of them.
  """
  def verification_changeset(channel, %{code: code, link: link}, now, ttl_hours \\ 24) do
    channel
    |> change(
      verification_code: presence(code),
      verification_link: presence(link),
      verification_captured_at: now,
      verification_expires_at: DateTime.add(now, ttl_hours * 3600, :second)
    )
    |> validate_length(:verification_code, max: 100)
    |> validate_length(:verification_link, max: 2048)
    |> validate_format(:verification_link, ~r/\Ahttps:\/\//, message: "must be an https link")
  end

  @doc "Clears a captured verification (expired or consumed)."
  def clear_verification_changeset(channel) do
    change(channel,
      verification_code: nil,
      verification_link: nil,
      verification_captured_at: nil,
      verification_expires_at: nil
    )
  end

  @doc """
  Changeset that issues a new ingress token and parks the current one as the
  previous token until `grace_until`.
  """
  def rotate_token_changeset(%__MODULE__{ingress_token: current} = channel, grace_until) do
    channel
    |> change(
      ingress_token: generate_token(),
      previous_ingress_token: current,
      previous_token_expires_at: grace_until
    )
    |> unique_constraint(:ingress_token)
    |> unique_constraint(:previous_ingress_token)
  end

  @doc "Changeset that retires the previous token."
  def retire_previous_token_changeset(channel) do
    change(channel, previous_ingress_token: nil, previous_token_expires_at: nil)
  end

  @doc "Changeset for system-managed health fields."
  def health_changeset(channel, attrs) do
    cast(channel, attrs, [:last_received_at, :quiet_notified_at])
  end

  @doc "Changeset recording a sending-domain check result."
  def sending_domain_changeset(channel, status, checked_at)
      when status in @sending_domain_statuses do
    change(channel, sending_domain_status: status, sending_domain_checked_at: checked_at)
  end

  @doc """
  The full ingress address, `local+token@domain`, or nil when the route has
  no known ingress domain yet.
  """
  def ingress_address(%__MODULE__{} = channel, domain) when is_binary(domain) and domain != "" do
    "#{channel.ingress_local}+#{channel.ingress_token}@#{domain}"
  end

  def ingress_address(%__MODULE__{}, _domain), do: nil

  @doc """
  Ingress address with the token masked for list views
  (`support+abcd…wxyz@domain`). nil without a domain.
  """
  def masked_ingress_address(%__MODULE__{} = channel, domain)
      when is_binary(domain) and domain != "" do
    token = channel.ingress_token

    "#{channel.ingress_local}+#{String.slice(token, 0, 4)}…#{String.slice(token, -4, 4)}@#{domain}"
  end

  def masked_ingress_address(%__MODULE__{}, _domain), do: nil

  @doc "Domain part of the public address."
  def public_domain(%__MODULE__{public_address: address}) when is_binary(address) do
    address |> String.split("@", parts: 2) |> List.last()
  end

  def public_domain(_channel), do: nil

  @doc "True while a previous (rotated) token is still inside its grace period."
  def previous_token_valid?(%__MODULE__{previous_ingress_token: nil}, _now), do: false

  def previous_token_valid?(%__MODULE__{previous_token_expires_at: nil}, _now), do: false

  def previous_token_valid?(%__MODULE__{previous_token_expires_at: expires}, now),
    do: DateTime.compare(expires, now) == :gt

  @doc "True while a captured verification has not expired."
  def verification_valid?(%__MODULE__{verification_expires_at: nil}, _now), do: false

  def verification_valid?(%__MODULE__{verification_expires_at: expires}, now),
    do: DateTime.compare(expires, now) == :gt

  @doc "True for channels that route by ingress token (forwarding channels)."
  def forwarding?(%__MODULE__{ingress_kind: :forward}), do: true
  def forwarding?(%__MODULE__{}), do: false

  @doc "States in which deliveries become conversations."
  def receiving?(%__MODULE__{state: state}),
    do: state in [:pending_verification, :awaiting_first_message, :active]

  @doc "Generate a 20-character lowercase Crockford base32 token (100 bits)."
  def generate_token do
    @token_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(@token_alphabet, rem(byte, 32)) end)
    |> List.to_string()
  end

  @doc "Lowercased, trimmed address; nil when blank."
  def normalize_address(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      address -> address
    end
  end

  def normalize_address(value), do: value

  # D8: only forwarding channels have a forwarding source to hint at or an
  # ingress address to reply from. A direct-MX channel has no mailbox, so an
  # archive copy BCC'd to the public address would only come straight back.
  # Every kind keeps an ingress token (the column is non-null), but only
  # forwarding channels route by it.
  defp validate_kind_rules(changeset) do
    case get_field(changeset, :ingress_kind) do
      :forward ->
        changeset

      kind ->
        changeset
        |> put_change(:provider, nil)
        |> validate_inclusion(:reply_from, [:public_address],
          message: "must be the public address for #{kind} channels"
        )
        |> validate_no_archive_copy(kind)
    end
  end

  defp validate_no_archive_copy(changeset, :mx) do
    if get_field(changeset, :archive_copy) == true,
      do: add_error(changeset, :archive_copy, "is not available for direct-MX channels"),
      else: changeset
  end

  defp validate_no_archive_copy(changeset, _kind), do: changeset

  # The ingress local part mirrors the public address local part. Characters
  # outside the conservative set are replaced so the derived value always
  # satisfies @local_regex when the public address is itself valid.
  defp put_ingress_local(changeset) do
    case get_field(changeset, :public_address) do
      address when is_binary(address) ->
        local =
          address
          |> String.split("@", parts: 2)
          |> List.first()
          |> String.replace(~r/[^a-z0-9._-]/, "-")
          |> String.replace(~r/\A[._-]+/, "")
          |> String.slice(0, @local_max_length)

        put_change(changeset, :ingress_local, if(local == "", do: "mail", else: local))

      _ ->
        changeset
    end
  end

  defp maybe_generate_token(changeset) do
    case get_field(changeset, :ingress_token) do
      nil -> put_change(changeset, :ingress_token, generate_token())
      _ -> changeset
    end
  end

  defp normalize_display_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      name -> name
    end
  end

  defp normalize_display_name(value), do: value

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp presence(_value), do: nil
end

defmodule Custyard.InboundChannel do
  @moduledoc """
  One public support address bound to an inbound route.

  A route is the Lettermint-backed ingress with organization and project
  scope; a channel is the staff-visible object on top of it: the public
  address customers write to (`support@companyname.com`), the ingress address
  the staff's mail service forwards to
  (`support+<token>@<route domain>`), the From identity for replies, and
  the lifecycle that tells the staff whether mail is flowing. See
  docs/design/spec-inbound-channels.md, decisions D1 to D4 and D7.

  ## States

      draft -> pending_verification -> awaiting_first_message -> active
                                   \\-> paused / revoked (from any state after draft)

  `Custyard.InboundChannels` owns every transition; this module only
  validates them.

  ## Ingress kinds (D8)

    * `forward`: the staff's mail service forwards to the ingress
      address; routed by token
    * `mx`: mail arrives at the public address on the route's custom
      domain. The local part has no `+`: `support+tag@` reaches `support@`
    * `imap`: Custyard reads one folder of a mailbox read-only
      (`imap_host`, `imap_port`, `imap_username`, `imap_folder`). The
      password is accepted through the virtual `imap_password` field and
      stored only as `Custyard.Credentials` ciphertext. `imap_uid_validity`
      and `imap_last_uid` mark how far the folder has been read.
      `imap_auth_failures` counts rejected logins since the last successful
      poll; `imap_message_attempts` counts sessions that stopped on the
      message at the current position.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states [:draft, :pending_verification, :awaiting_first_message, :active, :paused, :revoked]
  @ingress_kinds [:forward, :mx, :imap]
  # The largest state score (new) is 30; a bonus above it would let the
  # channel outweigh everything else.
  @max_attention_bonus 30
  # Forwarding source hint (D8): drives setup copy. `google` is per-user
  # Gmail forwarding with a confirmation email; `google_workspace` is admin
  # routing in the Admin console, which sends none.
  @providers [:proton, :google, :google_workspace, :other]
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
  @hostname_regex ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/
  @imap_password_context "inbound_channel.imap_password"
  @imap_fields [:imap_host, :imap_port, :imap_username, :imap_folder, :imap_password]
  # Changing any of these points the channel at a different mailbox or
  # folder: the UID position no longer applies and a login lockout is over.
  @imap_mailbox_fields [:imap_host, :imap_port, :imap_username, :imap_folder]

  schema "inbound_channels" do
    field(:tenant_id, :id)
    belongs_to(:tenant, Custyard.Tenant, define_field: false)
    field(:public_address, :string)
    field(:display_name, :string)

    field(:ingress_local, :string)
    field(:ingress_token, :string)
    field(:previous_ingress_token, :string)
    field(:previous_token_expires_at, :utc_datetime)

    field(:ingress_kind, Ecto.Enum, values: @ingress_kinds, default: :forward)
    field(:provider, Ecto.Enum, values: @providers)

    field(:state, Ecto.Enum, values: @states, default: :draft)

    field(:reply_from, Ecto.Enum, values: @reply_from_options, default: :public_address)
    field(:sending_domain, :string)
    # D4: BCC every outbound reply to the public address so the staff's
    # mailbox keeps a copy. Off by default; the copy is forwarded back and
    # recognised by triage as an own echo.
    field(:archive_copy, :boolean, default: false)
    # D9: per-message attachment cap in megabytes; 0 disables fetching.
    field(:attachment_limit_mb, :integer, default: 10)
    # Points added to the attention score of the channel's conversations
    # (Custyard.Scoring), so security@ can outrank sales@. 0 is neutral.
    field(:attention_bonus, :integer, default: 0)
    field(:sending_domain_status, :string)
    field(:sending_domain_checked_at, :utc_datetime)

    field(:verification_code, :string)
    field(:verification_link, :string)
    field(:verification_captured_at, :utc_datetime)
    field(:verification_expires_at, :utc_datetime)

    field(:imap_host, :string)
    field(:imap_port, :integer)
    field(:imap_username, :string)
    field(:imap_password, :string, virtual: true, redact: true)
    field(:imap_password_ciphertext, :string, redact: true)
    field(:imap_folder, :string)
    field(:imap_uid_validity, :integer)
    field(:imap_last_uid, :integer)
    field(:imap_last_polled_at, :utc_datetime)
    field(:imap_last_error, :string)
    field(:imap_consecutive_failures, :integer, default: 0)
    field(:imap_auth_failures, :integer, default: 0)
    field(:imap_message_attempts, :integer, default: 0)
    field(:imap_auth_failed_at, :utc_datetime)

    field(:verified_at, :utc_datetime)
    field(:last_received_at, :utc_datetime)
    field(:quiet_after_hours, :integer, default: 72)
    field(:quiet_notified_at, :utc_datetime)
    field(:paused_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)

    belongs_to(:inbound_route, Custyard.InboundRoute)
    belongs_to(:default_organization, Custyard.Organization)
    belongs_to(:default_project, Custyard.Project)
    belongs_to(:default_label, Custyard.Label)

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def ingress_kinds, do: @ingress_kinds

  @doc "The largest attention bonus a channel can carry."
  def max_attention_bonus, do: @max_attention_bonus
  def providers, do: @providers
  def reply_from_options, do: @reply_from_options
  def sending_domain_statuses, do: @sending_domain_statuses
  def token_length, do: @token_length
  def transitions, do: @transitions
  def imap_password_context, do: @imap_password_context

  @doc """
  Changeset for staff-editable attributes at creation and update.

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
      :sending_domain,
      :quiet_after_hours,
      :archive_copy,
      :attachment_limit_mb,
      :attention_bonus,
      :inbound_route_id,
      :default_organization_id,
      :tenant_id,
      :default_project_id,
      :default_label_id
      | @imap_fields
    ])
    |> update_change(:public_address, &normalize_address/1)
    |> update_change(:sending_domain, &normalize_address/1)
    |> update_change(:display_name, &normalize_display_name/1)
    |> validate_required([:public_address, :ingress_kind, :inbound_route_id, :tenant_id])
    |> foreign_key_constraint(:tenant_id)
    |> validate_length(:public_address, max: 255)
    |> validate_format(:public_address, @email_regex, message: "must be a valid email address")
    |> validate_length(:display_name, max: 100)
    |> validate_length(:sending_domain, max: 253)
    |> validate_format(:sending_domain, @hostname_regex,
      message: "must be a domain such as mail.example.com"
    )
    |> validate_change(:sending_domain, fn :sending_domain, domain ->
      if Enum.any?(String.split(domain, "."), &(byte_size(&1) > 63)),
        do: [sending_domain: "domain labels must be at most 63 characters"],
        else: []
    end)
    |> validate_sending_address_length()
    |> reset_sending_domain_check()
    |> validate_number(:quiet_after_hours,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 720
    )
    |> validate_number(:attachment_limit_mb,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:attention_bonus,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_attention_bonus
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
    |> foreign_key_constraint(:default_organization_id)
    |> foreign_key_constraint(:default_project_id)
    |> foreign_key_constraint(:default_label_id)
    |> validate_hint_tenants()
  end

  defp validate_hint_tenants(changeset) do
    Enum.reduce(
      [
        {:inbound_route_id, Custyard.InboundRoute},
        {:default_organization_id, Custyard.Organization},
        {:default_project_id, Custyard.Project},
        {:default_label_id, Custyard.Label}
      ],
      changeset,
      fn {field, schema}, acc ->
        case get_field(acc, field) && Custyard.Repo.get(schema, get_field(acc, field)) do
          %{tenant_id: tenant_id} ->
            if tenant_id == get_field(acc, :tenant_id),
              do: acc,
              else: add_error(acc, field, "must belong to the same tenant")

          _ ->
            acc
        end
      end
    )
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

  @doc """
  Changeset for the poller's own bookkeeping: UID position, last poll,
  failure counters, and re-encryption of the password under a new key.
  """
  def imap_state_changeset(channel, attrs) do
    cast(channel, attrs, [
      :imap_uid_validity,
      :imap_last_uid,
      :imap_last_polled_at,
      :imap_last_error,
      :imap_consecutive_failures,
      :imap_auth_failures,
      :imap_message_attempts,
      :imap_auth_failed_at,
      :imap_password_ciphertext
    ])
    |> validate_length(:imap_last_error, max: 64)
  end

  @doc "Decrypt the stored IMAP password. `{:ok, password}` or `{:error, :invalid}`."
  def imap_password(%__MODULE__{imap_password_ciphertext: ciphertext}) when is_binary(ciphertext),
    do: Custyard.Credentials.decrypt(ciphertext, @imap_password_context)

  def imap_password(%__MODULE__{}), do: {:error, :invalid}

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

  @doc "The selected sending domain, defaulting to the public mailbox's domain."
  def sending_domain(%__MODULE__{sending_domain: domain}) when is_binary(domain), do: domain
  def sending_domain(%__MODULE__{} = channel), do: public_domain(channel)

  @doc "The public mailbox local part at the selected sending domain."
  def sending_address(%__MODULE__{public_address: address} = channel) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [local, _domain] -> local <> "@" <> sending_domain(channel)
      _ -> nil
    end
  end

  def sending_address(_channel), do: nil

  defp reset_sending_domain_check(changeset) do
    if changed?(changeset, :sending_domain),
      do: change(changeset, sending_domain_status: nil, sending_domain_checked_at: nil),
      else: changeset
  end

  defp validate_sending_address_length(changeset) do
    address = changeset |> apply_changes() |> sending_address()

    if is_binary(address) and byte_size(address) > 255,
      do:
        add_error(changeset, :sending_domain, "makes the sending address longer than 255 bytes"),
      else: changeset
  end

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
        drop_imap_changes(changeset)

      kind ->
        changeset
        |> put_change(:provider, nil)
        |> validate_inclusion(:reply_from, [:public_address],
          message: "must be the public address for #{kind} channels"
        )
        |> validate_no_archive_copy(kind)
        |> validate_no_subaddress(kind)
        |> validate_imap(kind)
    end
  end

  defp drop_imap_changes(changeset),
    do: Enum.reduce(@imap_fields, changeset, &delete_change(&2, &1))

  defp validate_imap(changeset, :imap) do
    changeset
    |> update_change(:imap_host, &normalize_address/1)
    |> update_change(:imap_username, &trim_or_nil/1)
    |> update_change(:imap_folder, &trim_or_nil/1)
    |> put_default(:imap_port, 993)
    |> put_default(:imap_folder, "INBOX")
    |> validate_required([:imap_host, :imap_port, :imap_username, :imap_folder])
    |> validate_length(:imap_host, max: 255)
    |> validate_imap_host()
    |> validate_number(:imap_port, greater_than: 0, less_than: 65_536)
    |> validate_length(:imap_username, max: 320)
    |> validate_length(:imap_folder, max: 255)
    |> validate_format(:imap_folder, ~r/\A[^\x00-\x1f\x7f]+\z/, message: "has invalid characters")
    |> validate_length(:imap_password, max: 1024)
    |> reset_mailbox_position()
    |> encrypt_imap_password()
  end

  defp validate_imap(changeset, _kind), do: drop_imap_changes(changeset)

  defp put_default(changeset, field, value) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, value),
      else: changeset
  end

  # Only names: an IP literal or a single-label host would let a channel
  # point the poller at the instance's own network. Development can allow
  # them (`config :custyard, :imap_allow_private_hosts, true`) for a local
  # test server; the poller checks resolved addresses again at connect time.
  defp validate_imap_host(changeset) do
    if Application.get_env(:custyard, :imap_allow_private_hosts, false),
      do: changeset,
      else:
        validate_format(changeset, :imap_host, @hostname_regex, message: "must be a host name")
  end

  defp reset_mailbox_position(changeset) do
    if Enum.any?(@imap_mailbox_fields ++ [:imap_password], &Map.has_key?(changeset.changes, &1)) do
      changeset
      |> put_change(:imap_auth_failed_at, nil)
      |> put_change(:imap_last_error, nil)
      |> put_change(:imap_consecutive_failures, 0)
      |> put_change(:imap_auth_failures, 0)
      |> reset_uid_position()
    else
      changeset
    end
  end

  defp reset_uid_position(changeset) do
    if Enum.any?(@imap_mailbox_fields, &Map.has_key?(changeset.changes, &1)),
      do:
        changeset
        |> put_change(:imap_uid_validity, nil)
        |> put_change(:imap_last_uid, nil)
        |> put_change(:imap_message_attempts, 0),
      else: changeset
  end

  # The plaintext never stays in the changeset: it is replaced by the
  # ciphertext, and a missing key is a form error rather than a plaintext
  # fallback.
  defp encrypt_imap_password(changeset) do
    case fetch_change(changeset, :imap_password) do
      {:ok, password} when is_binary(password) and password != "" ->
        changeset = delete_change(changeset, :imap_password)

        case Custyard.Credentials.encrypt(password, @imap_password_context) do
          {:ok, ciphertext} ->
            put_change(changeset, :imap_password_ciphertext, ciphertext)

          {:error, :not_configured} ->
            add_error(
              changeset,
              :imap_password,
              "cannot be stored: CREDENTIAL_ENCRYPTION_KEY is not set"
            )
        end

      _ ->
        changeset = delete_change(changeset, :imap_password)

        if is_nil(get_field(changeset, :imap_password_ciphertext)),
          do: add_error(changeset, :imap_password, "can't be blank", validation: :required),
          else: changeset
    end
  end

  defp validate_no_archive_copy(changeset, :mx) do
    if get_field(changeset, :archive_copy) == true,
      do: add_error(changeset, :archive_copy, "is not available for direct-MX channels"),
      else: changeset
  end

  defp validate_no_archive_copy(changeset, _kind), do: changeset

  # Direct mail is matched on the address without its `+tag`, so a public
  # address with a tag could never receive its own mail.
  defp validate_no_subaddress(changeset, :mx) do
    validate_format(changeset, :public_address, ~r/\A[^+@]+@/,
      message: "can't contain +; mail to support+anything@ already reaches support@"
    )
  end

  defp validate_no_subaddress(changeset, _kind), do: changeset

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

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: value

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

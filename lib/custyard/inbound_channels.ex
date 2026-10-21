defmodule Custyard.InboundChannels do
  @moduledoc """
  Context for inbound channels: the operator-visible public addresses bound
  to an inbound route (docs/design/spec-inbound-channels.md).

  Responsibilities:

    * CRUD and the D7 lifecycle (`create_channel/2`, `confirm_verification/1`,
      `pause/1`, `resume/1`, `revoke/1`, `rotate_token/2`)
    * Routing: `resolve_for_delivery/2` maps a delivery's envelope recipient
      to a channel on the route by token (D2)
    * Health: `mark_received/2` on every accepted delivery, the quiet-channel
      check, and the rejection log
    * Audit events for every admin action

  PubSub: channel changes broadcast `{:channel_updated, channel_id}` on
  `"channel:<id>"` and on `"organization:<org_id>:channels"`.
  """

  import Ecto.Query

  require Logger

  alias Custyard.{AuditEvent, InboundChannel, InboundChannelRejection, InboundRoute, Repo}

  @rejection_retention_days 14
  @default_rotation_grace_hours 7 * 24

  # --- Reads ---

  @doc "Channels for an organization, newest first, with route and project preloaded."
  def list_for_organization(organization_id) when is_integer(organization_id) do
    from(c in InboundChannel,
      where: c.organization_id == ^organization_id,
      order_by: [asc: c.state, asc: c.public_address],
      preload: [:inbound_route, :project]
    )
    |> Repo.all()
  end

  @doc "Channels bound to a route."
  def list_for_route(route_id) when is_integer(route_id) do
    from(c in InboundChannel,
      where: c.inbound_route_id == ^route_id,
      order_by: [asc: c.id],
      preload: [:inbound_route, :project]
    )
    |> Repo.all()
  end

  @doc "True when the route has at least one channel (so routing by token applies)."
  def route_has_channels?(route_id) when is_integer(route_id) do
    Repo.exists?(from c in InboundChannel, where: c.inbound_route_id == ^route_id)
  end

  def get_channel(id) when is_integer(id) do
    InboundChannel |> Repo.get(id) |> Repo.preload([:inbound_route, :project, :organization])
  end

  def get_channel!(id) when is_integer(id) do
    InboundChannel |> Repo.get!(id) |> Repo.preload([:inbound_route, :project, :organization])
  end

  @doc "Channel scoped to an organization; nil when absent or owned elsewhere."
  def get_channel_for_organization(id, organization_id)
      when is_integer(id) and is_integer(organization_id) do
    from(c in InboundChannel,
      where: c.id == ^id and c.organization_id == ^organization_id,
      preload: [:inbound_route, :project, :organization]
    )
    |> Repo.one()
  end

  @doc "Changeset for form rendering."
  def change_channel(%InboundChannel{} = channel, attrs \\ %{}),
    do: InboundChannel.changeset(channel, attrs)

  # --- Addresses ---

  @doc """
  The ingress address customers' mail is forwarded to, or nil when the
  route's ingress domain is not known yet. Accepts a channel with the route
  preloaded, or loads it.
  """
  def ingress_address(%InboundChannel{} = channel) do
    InboundChannel.ingress_address(channel, ingress_domain(channel))
  end

  @doc "Masked ingress address for lists."
  def masked_ingress_address(%InboundChannel{} = channel) do
    InboundChannel.masked_ingress_address(channel, ingress_domain(channel))
  end

  @doc """
  The From address for operator replies on this channel (D3): the public
  address, or the full ingress address when the channel falls back to the
  ingress identity. nil when the fallback is selected but the route has no
  domain yet (callers then use their own fallback).
  """
  def from_address(%InboundChannel{reply_from: :public_address, public_address: address}),
    do: address

  def from_address(%InboundChannel{reply_from: :ingress_address} = channel),
    do: ingress_address(channel)

  @doc "From display name: channel display name, else nil (callers fall back to the org name)."
  def from_name(%InboundChannel{display_name: name}) when is_binary(name) and name != "",
    do: name

  def from_name(_channel), do: nil

  defp ingress_domain(%InboundChannel{inbound_route: %InboundRoute{} = route}),
    do: InboundRoute.ingress_domain(route)

  defp ingress_domain(%InboundChannel{inbound_route_id: route_id}) when is_integer(route_id) do
    case Repo.get(InboundRoute, route_id) do
      nil -> nil
      route -> InboundRoute.ingress_domain(route)
    end
  end

  defp ingress_domain(_channel), do: nil

  # --- Lifecycle ---

  @doc """
  Create a channel on a route. The channel starts in `pending_verification`:
  the setup screen shows the ingress address immediately, which is the D7
  trigger for that state. `attrs` carries `public_address`, optional
  `display_name`, `provider`, `reply_from`; route, organization and project
  come from the route.

  `opts[:operator]` is recorded on the audit event.
  """
  def create_channel(%InboundRoute{} = route, attrs, opts \\ []) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("inbound_route_id", route.id)
      |> Map.put("organization_id", route.organization_id)
      |> Map.put("project_id", route.project_id)

    changeset =
      %InboundChannel{}
      |> InboundChannel.changeset(attrs)
      |> Ecto.Changeset.put_change(:state, :pending_verification)

    with {:ok, channel} <- Repo.insert(changeset) do
      audit(channel, :channel_created, opts, %{
        public_address: channel.public_address,
        provider: channel.provider,
        ingress_kind: channel.ingress_kind
      })

      broadcast(channel)
      {:ok, Repo.preload(channel, [:inbound_route, :project])}
    end
  end

  @doc "Update operator-editable attributes (display name, provider, reply_from, quiet window)."
  def update_channel(%InboundChannel{} = channel, attrs, opts \\ []) when is_map(attrs) do
    attrs = Map.drop(Map.new(attrs, fn {k, v} -> {to_string(k), v} end), ~w(public_address))

    with {:ok, updated} <- channel |> InboundChannel.changeset(attrs) |> Repo.update() do
      audit(updated, :channel_updated, opts, %{changed: Map.keys(attrs)})
      broadcast(updated)
      {:ok, updated}
    end
  end

  @doc """
  Operator confirmed the forwarding rule: `pending_verification` ->
  `awaiting_first_message`. Consumes any captured verification.
  """
  def confirm_verification(%InboundChannel{} = channel, opts \\ []) do
    now = now()

    channel
    |> InboundChannel.state_changeset(:awaiting_first_message, %{verified_at: now})
    |> Ecto.Changeset.merge(InboundChannel.clear_verification_changeset(channel))
    |> transition(channel, opts)
  end

  @doc "Store a provider forwarding confirmation captured by triage (D6)."
  def capture_verification(%InboundChannel{} = channel, %{} = capture, opts \\ []) do
    now = now()
    capture = %{code: Map.get(capture, :code), link: Map.get(capture, :link)}

    with {:ok, updated} <-
           channel |> InboundChannel.verification_changeset(capture, now) |> Repo.update() do
      audit(updated, :channel_verification_captured, opts, %{
        has_code: not is_nil(updated.verification_code),
        has_link: not is_nil(updated.verification_link)
      })

      broadcast(updated)
      {:ok, updated}
    end
  end

  @doc "Pause: deliveries are logged to the rejection log instead of becoming conversations."
  def pause(%InboundChannel{} = channel, opts \\ []) do
    channel
    |> InboundChannel.state_changeset(:paused, %{paused_at: now()})
    |> transition(channel, opts)
  end

  @doc """
  Resume a paused channel to the state it would otherwise be in: `active`
  once it has received mail, `awaiting_first_message` once verified, else
  `pending_verification`.
  """
  def resume(channel, opts \\ [])

  def resume(%InboundChannel{state: :paused} = channel, opts) do
    target =
      cond do
        channel.last_received_at -> :active
        channel.verified_at -> :awaiting_first_message
        true -> :pending_verification
      end

    channel
    |> InboundChannel.state_changeset(target, %{paused_at: nil})
    |> transition(channel, opts)
  end

  def resume(%InboundChannel{} = channel, _opts), do: {:error, invalid_state(channel, :resume)}

  @doc "Revoke: every token stops matching immediately. Terminal."
  def revoke(%InboundChannel{} = channel, opts \\ []) do
    channel
    |> InboundChannel.state_changeset(:revoked, %{revoked_at: now()})
    |> Ecto.Changeset.merge(InboundChannel.retire_previous_token_changeset(channel))
    |> transition(channel, opts)
  end

  @doc """
  Issue a new ingress token. The old token keeps matching for
  `opts[:grace_hours]` (default 168) so the forwarding rule can be updated.
  """
  def rotate_token(channel, opts \\ [])

  def rotate_token(%InboundChannel{state: :revoked} = channel, _opts),
    do: {:error, invalid_state(channel, :rotate_token)}

  def rotate_token(%InboundChannel{} = channel, opts) do
    grace_hours = Keyword.get(opts, :grace_hours, @default_rotation_grace_hours)
    grace_until = DateTime.add(now(), grace_hours * 3600, :second)

    with {:ok, updated} <-
           channel |> InboundChannel.rotate_token_changeset(grace_until) |> Repo.update() do
      audit(updated, :channel_token_rotated, opts, %{grace_hours: grace_hours})
      broadcast(updated)
      {:ok, updated}
    end
  end

  @doc """
  Record that an operator revealed the full ingress address. The address
  itself is read from the channel; this only leaves the audit trail D7 asks
  for.
  """
  def record_reveal(%InboundChannel{} = channel, opts \\ []) do
    audit(channel, :channel_token_revealed, opts, %{})
    :ok
  end

  @doc "Delete a channel outright (admin). Prefer `revoke/2` for offboarding."
  def delete_channel(%InboundChannel{} = channel, opts \\ []) do
    with {:ok, deleted} <- Repo.delete(channel) do
      audit(deleted, :channel_deleted, opts, %{public_address: deleted.public_address})
      broadcast(deleted)
      {:ok, deleted}
    end
  end

  defp transition(changeset, channel, opts) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        audit(updated, :channel_state_changed, opts, %{from: channel.state, to: updated.state})
        broadcast(updated)
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  defp invalid_state(channel, action) do
    channel
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:state, "cannot #{action} a channel in state #{channel.state}")
  end

  # --- Routing (D2) ---

  @doc """
  Map a delivery to a channel on `route` from its envelope recipient.

  Returns:

    * `{:ok, channel}` for a receiving channel whose current or in-grace
      previous token matches the recipient's subaddress
    * `{:paused, channel}` / `{:revoked, channel}` when the token matched a
      channel that must not create conversations
    * `:legacy` when the route has no channels at all (routes created before
      channels exist keep working as one implicit channel)
    * `{:error, :no_channel}` when the route has channels but nothing matched

  Only the recipient (`data.recipient`, falling back to `normalized.to`) is
  consulted, never To/Cc. Local part and token are compared lowercased.
  """
  def resolve_for_delivery(%InboundRoute{id: route_id}, recipient) do
    channels = list_for_route(route_id)

    cond do
      channels == [] ->
        :legacy

      true ->
        case parse_recipient(recipient) do
          {:ok, _local, token} -> match_token(channels, token)
          :error -> {:error, :no_channel}
        end
    end
  end

  defp match_token(channels, token) do
    now = now()

    matched =
      Enum.find(channels, fn channel ->
        channel.ingress_token == token or
          (channel.previous_ingress_token == token and
             InboundChannel.previous_token_valid?(channel, now))
      end)

    case matched do
      nil -> {:error, :no_channel}
      %InboundChannel{state: :paused} = channel -> {:paused, channel}
      %InboundChannel{state: :revoked} = channel -> {:revoked, channel}
      %InboundChannel{state: :draft} -> {:error, :no_channel}
      channel -> {:ok, channel}
    end
  end

  @doc false
  def parse_recipient(recipient) when is_binary(recipient) do
    with [local, _domain] <- recipient |> String.trim() |> String.downcase() |> String.split("@"),
         [base, token] <- String.split(local, "+", parts: 2),
         true <- base != "" and token != "" do
      {:ok, base, token}
    else
      _ -> :error
    end
  end

  def parse_recipient(_recipient), do: :error

  # --- Health ---

  @doc """
  Record an accepted delivery on the channel: stamps `last_received_at`,
  clears a pending quiet notice, and moves `pending_verification` or
  `awaiting_first_message` to `active`.
  """
  def mark_received(%InboundChannel{} = channel, at \\ nil) do
    at = at || now()

    changeset =
      InboundChannel.health_changeset(channel, %{last_received_at: at, quiet_notified_at: nil})

    changeset =
      if channel.state in [:pending_verification, :awaiting_first_message] do
        Ecto.Changeset.merge(
          changeset,
          InboundChannel.state_changeset(channel, :active, %{
            verified_at: channel.verified_at || at
          })
        )
      else
        changeset
      end

    case Repo.update(changeset) do
      {:ok, updated} ->
        if updated.state != channel.state do
          audit(updated, :channel_state_changed, [], %{from: channel.state, to: updated.state})
        end

        broadcast(updated)
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Active channels that received mail before and have been quiet longer than
  their `quiet_after_hours`, not yet notified for this quiet period.
  """
  def list_quiet_channels(now \\ nil) do
    now = now || now()

    from(c in InboundChannel,
      where: c.state == :active and not is_nil(c.last_received_at),
      where: is_nil(c.quiet_notified_at) or c.quiet_notified_at < c.last_received_at,
      preload: [:inbound_route, :organization]
    )
    |> Repo.all()
    |> Enum.filter(fn channel ->
      cutoff = DateTime.add(now, -channel.quiet_after_hours * 3600, :second)
      DateTime.compare(channel.last_received_at, cutoff) == :lt
    end)
  end

  @doc "Mark a quiet notice as sent."
  def mark_quiet_notified(%InboundChannel{} = channel, at \\ nil) do
    channel
    |> InboundChannel.health_changeset(%{quiet_notified_at: at || now()})
    |> Repo.update()
  end

  # --- Rejection log ---

  @doc """
  Record a delivery that did not become a customer message. `attrs` carries
  `sender_email`, `recipient`, `subject`, `provider_delivery_id`, and
  optionally `inbound_channel_id`. Never raises: a failure here must not
  fail the webhook.
  """
  def log_rejection(%InboundRoute{} = route, classification, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("classification", classification)
      |> Map.put("inbound_route_id", route.id)
      |> Map.put("organization_id", route.organization_id)
      |> Map.update("subject", nil, &truncate(&1, 500))

    case %InboundChannelRejection{}
         |> InboundChannelRejection.changeset(attrs)
         |> Repo.insert() do
      {:ok, rejection} ->
        {:ok, rejection}

      {:error, changeset} ->
        Logger.warning(
          "Inbound rejection log insert failed on route #{route.id}: #{inspect(Keyword.keys(changeset.errors))}"
        )

        {:error, changeset}
    end
  end

  @doc "Rejections for a route, newest first."
  def list_rejections_for_route(route_id, opts \\ []) when is_integer(route_id) do
    limit = Keyword.get(opts, :limit, 100)

    from(r in InboundChannelRejection,
      where: r.inbound_route_id == ^route_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Rejections for an organization, newest first."
  def list_rejections_for_organization(organization_id, opts \\ [])
      when is_integer(organization_id) do
    limit = Keyword.get(opts, :limit, 100)

    from(r in InboundChannelRejection,
      where: r.organization_id == ^organization_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Retention sweep: deletes rejections older than 14 days, clears expired
  verification captures, and retires previous tokens past their grace
  period. Returns counts.
  """
  def sweep_expired(now \\ nil) do
    now = now || now()
    rejection_cutoff = DateTime.add(now, -@rejection_retention_days * 86_400, :second)

    {rejections, _} =
      from(r in InboundChannelRejection, where: r.inserted_at < ^rejection_cutoff)
      |> Repo.delete_all()

    {verifications, _} =
      from(c in InboundChannel,
        where: not is_nil(c.verification_expires_at) and c.verification_expires_at < ^now
      )
      |> Repo.update_all(
        set: [
          verification_code: nil,
          verification_link: nil,
          verification_captured_at: nil,
          verification_expires_at: nil,
          updated_at: now
        ]
      )

    {tokens, _} =
      from(c in InboundChannel,
        where: not is_nil(c.previous_token_expires_at) and c.previous_token_expires_at < ^now
      )
      |> Repo.update_all(
        set: [previous_ingress_token: nil, previous_token_expires_at: nil, updated_at: now]
      )

    %{rejections: rejections, verifications: verifications, tokens: tokens}
  end

  # --- Internals ---

  @doc false
  def broadcast(%InboundChannel{} = channel) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "channel:#{channel.id}",
      {:channel_updated, channel.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "organization:#{channel.organization_id}:channels",
      {:channel_updated, channel.id}
    )

    :ok
  end

  @doc false
  def subscribe(%InboundChannel{id: id}),
    do: Phoenix.PubSub.subscribe(Custyard.PubSub, "channel:#{id}")

  @doc false
  def subscribe_organization(organization_id),
    do: Phoenix.PubSub.subscribe(Custyard.PubSub, "organization:#{organization_id}:channels")

  # Audit payloads never carry the ingress token or any message content.
  defp audit(%InboundChannel{} = channel, event_type, opts, payload) do
    operator = Keyword.get(opts, :operator)

    attrs = %{
      event_type: event_type,
      source: "inbound_channels",
      organization_id: channel.organization_id,
      project_id: channel.project_id,
      payload:
        payload
        |> Map.put(:channel_id, channel.id)
        |> Map.put(:operator_id, operator && operator.id)
        |> Map.new(fn {k, v} -> {to_string(k), audit_value(v)} end)
    }

    case AuditEvent.create(attrs) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Audit event #{event_type} for channel #{channel.id} failed: #{inspect(Keyword.keys(changeset.errors))}"
        )

        :ok
    end
  end

  defp audit_value(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp audit_value(value) when is_list(value), do: Enum.map(value, &audit_value/1)
  defp audit_value(value), do: value

  defp truncate(nil, _max), do: nil
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max)
  defp truncate(other, _max), do: other

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

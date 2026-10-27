defmodule Custyard.EmailSetup do
  @moduledoc "Tenant email setup, encrypted credentials and observed delivery evidence."
  import Ecto.Query

  alias Custyard.{
    Credentials,
    EmailConnection,
    InboundRoute,
    InboundRoutes,
    OperatorAccess,
    OperatorAccount,
    Repo,
    Tenant
  }

  alias Custyard.Email.{DeliveryStatus, ThreadHeaders}
  alias Custyard.Lettermint.HttpClient

  @status_events ~w(message.sent message.delivered message.hard_bounced message.failed message.policy_rejected message.suppressed)
  def status_events, do: @status_events

  def connection(tenant_id), do: Repo.get_by(EmailConnection, tenant_id: tenant_id)

  def default_reply_channel(tenant_id) do
    case connection(tenant_id) do
      %EmailConnection{default_channel_id: id} when is_integer(id) ->
        case Repo.get_by(Custyard.InboundChannel, id: id, tenant_id: tenant_id, state: :active) do
          nil -> {:error, :no_default_channel}
          channel -> {:ok, Repo.preload(channel, :inbound_route)}
        end

      _ ->
        case Repo.all(
               from(c in Custyard.InboundChannel,
                 where: c.tenant_id == ^tenant_id and c.state == :active,
                 limit: 2,
                 preload: [:inbound_route]
               )
             ) do
          [channel] -> {:ok, channel}
          [] -> {:error, :no_default_channel}
          _ -> {:error, :ambiguous_channels}
        end
    end
  end

  def set_default_channel(operator, tenant_id, channel_id) do
    mutate(operator, tenant_id, fn ->
      with {:ok, connection} <- do_ensure_connection(tenant_id),
           {:ok, id} <- parse_channel_id(channel_id),
           true <-
             is_nil(id) or
               Repo.exists?(
                 from(c in Custyard.InboundChannel,
                   where: c.id == ^id and c.tenant_id == ^tenant_id and c.state == :active
                 )
               ) do
        connection
        |> Ecto.Changeset.change(
          default_channel_id: id,
          last_reply_accepted_at: nil,
          last_reply_delivered_at: nil,
          last_returning_reply_at: nil,
          reply_evidence_after_message_id: message_high_water_mark()
        )
        |> Ecto.Changeset.foreign_key_constraint(:default_channel_id)
        |> Repo.update()
      else
        false -> {:error, :no_default_channel}
        error -> error
      end
    end)
  end

  defp parse_channel_id(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_channel_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_channel_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :no_default_channel}
    end
  end

  defp parse_channel_id(_), do: {:error, :no_default_channel}

  def summary(tenant_id) do
    connection = connection(tenant_id)
    receiving = not is_nil(connection && connection.last_signed_inbound_at)
    sending = not is_nil(connection && connection.last_reply_accepted_at)
    delivered = not is_nil(connection && connection.last_reply_delivered_at)
    returning = not is_nil(connection && connection.last_returning_reply_at)

    %{
      configured?: not is_nil(connection && connection.project_id),
      receiving?: receiving,
      sending?: sending,
      delivered?: delivered,
      returning?: returning,
      complete?: receiving and sending and delivered and returning
    }
  end

  def credential_status(tenant_id, field) when field in ["project_token", "team_token"] do
    connection = connection(tenant_id)

    cond do
      connection &&
          is_binary(Map.get(connection, String.to_existing_atom(field <> "_ciphertext"))) ->
        :saved

      default_tenant?(tenant_id) and match?({:ok, _}, env_credential(field)) ->
        :installation

      true ->
        :missing
    end
  end

  def authorized?(%{role: "super_admin"}, tenant_id), do: not is_nil(Repo.get(Tenant, tenant_id))
  def authorized?(%{role: "admin", tenant_id: tenant_id}, tenant_id), do: true
  def authorized?(_, _), do: false

  def ensure_connection(operator, tenant_id),
    do: mutate(operator, tenant_id, fn -> do_ensure_connection(tenant_id) end)

  defp do_ensure_connection(tenant_id) do
    case connection(tenant_id) do
      nil ->
        %EmailConnection{status_callback_token: token()}
        |> EmailConnection.changeset(%{tenant_id: tenant_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :tenant_id)
        |> case do
          {:ok, _} -> {:ok, connection(tenant_id)}
          error -> error
        end

      connection ->
        {:ok, connection}
    end
  end

  def save_credentials(operator, tenant_id, attrs) do
    mutate(operator, tenant_id, fn ->
      with {:ok, connection} <- do_ensure_connection(tenant_id),
           {:ok, secrets} <- encrypt_inputs(connection, attrs, ~w(project_token team_token)) do
        changeset = EmailConnection.changeset(connection, Map.take(attrs, ["project_id"]))
        changeset = protect_bound_project(changeset, tenant_id)
        changed = secrets != %{} or Ecto.Changeset.changed?(changeset, :project_id)

        changeset
        |> Ecto.Changeset.change(secrets)
        |> invalidate_checks(changed)
        |> Repo.update()
        |> case do
          {:ok, saved} ->
            if changed, do: invalidate_identity(tenant_id)
            {:ok, Repo.reload!(saved)}

          error ->
            error
        end
      end
    end)
  end

  defp protect_bound_project(changeset, tenant_id) do
    if is_binary(changeset.data.project_id) and Ecto.Changeset.changed?(changeset, :project_id) and
         Repo.exists?(
           from(r in InboundRoute, where: r.tenant_id == ^tenant_id and r.source == :lettermint)
         ) do
      Ecto.Changeset.add_error(
        changeset,
        :project_id,
        "cannot change while receiving routes are connected"
      )
    else
      changeset
    end
  end

  defp invalidate_checks(changeset, false), do: changeset

  defp invalidate_checks(changeset, true) do
    Ecto.Changeset.change(changeset,
      project_checked_at: nil,
      project_check_status: "unchecked",
      sending_checked_at: nil,
      sending_check_status: "unchecked",
      last_signed_inbound_at: nil,
      latest_received_conversation_id: nil,
      last_returning_reply_at: nil,
      last_reply_accepted_at: nil,
      last_reply_delivered_at: nil
    )
  end

  def check_connection(operator, tenant_id) do
    with :ok <- authorize(operator, tenant_id),
         %EmailConnection{} = connection <- connection(tenant_id) do
      snapshot = configuration_snapshot(connection)

      management =
        with {:ok, opts} <- snapshot.management,
             id when is_binary(id) and id != "" <- connection.project_id,
             {:ok, %{"id" => ^id}} <- provider().get_project(id, opts),
             do: :ok

      sending =
        with {:ok, opts} <- snapshot.sending,
             token when is_binary(token) <- opts[:api_token],
             do: provider().ping_sending(token, api_options())

      mutate(operator, tenant_id, fn ->
        current = current_configuration!(tenant_id, snapshot)

        current
        |> Ecto.Changeset.change(
          project_checked_at: now(),
          project_check_status: check_status(management),
          sending_checked_at: now(),
          sending_check_status: check_status(sending)
        )
        |> Repo.update()
      end)
    else
      nil -> {:error, :not_configured}
      error -> error
    end
  end

  def import_route(operator, tenant_id, remote_id) when is_binary(remote_id) do
    with :ok <- authorize(operator, tenant_id),
         %EmailConnection{project_id: project_id} = connection when is_binary(project_id) <-
           connection(tenant_id),
         snapshot = configuration_snapshot(connection),
         {:ok, opts} <- snapshot.management,
         {:ok, remote} <- provider().get_route(String.trim(remote_id), opts),
         true <- remote["project_id"] == project_id and remote["route_type"] == "inbound",
         true <- is_binary(remote["id"]) and remote["id"] != "",
         true <- is_binary(remote["inbound_route_domain"]) do
      mutate(operator, tenant_id, fn ->
        current_configuration!(tenant_id, snapshot)
        # The actor write lock serializes local imports before checking ownership.
        case Repo.get_by(InboundRoute, lettermint_route_id: remote["id"]) do
          %InboundRoute{tenant_id: ^tenant_id} = existing ->
            InboundRoutes.ensure_default_webhooks(existing)

          %InboundRoute{} ->
            {:error, :wrong_tenant}

          nil ->
            %InboundRoute{}
            |> InboundRoute.changeset(%{
              tenant_id: tenant_id,
              source: :lettermint,
              route_type: :general,
              lettermint_route_id: remote["id"],
              lettermint_route_domain: remote["inbound_route_domain"],
              lettermint_inbound_address: remote["inbound_address"]
            })
            |> Repo.insert()
            |> case do
              {:ok, route} -> InboundRoutes.ensure_default_webhooks(route)
              error -> error
            end
        end
      end)
    else
      false -> {:error, :wrong_project_or_route}
      nil -> {:error, :project_required}
      error -> error
    end
  end

  def bind_inbound_webhook(operator, tenant_id, route_id, webhook_id, secret) do
    with :ok <- authorize(operator, tenant_id),
         %EmailConnection{} = connection <- connection(tenant_id),
         snapshot = configuration_snapshot(connection),
         %InboundRoute{tenant_id: ^tenant_id} = route <- Repo.get(InboundRoute, route_id),
         {:ok, opts} <- snapshot.management,
         {:ok, remote} <- provider().get_webhook(String.trim(webhook_id), opts),
         true <- valid_inbound_webhook?(remote, route),
         {:ok, ciphertext} <- encrypt_secret(secret, route_context(route)) do
      mutate(operator, tenant_id, fn ->
        current_configuration!(tenant_id, snapshot)

        current_route!(route)
        |> Ecto.Changeset.change(
          lettermint_webhook_id: remote["id"],
          webhook_secret_ciphertext: ciphertext,
          webhook_verified_at: nil
        )
        |> Repo.update()
        |> case do
          {:ok, bound} ->
            invalidate_receiving(tenant_id)
            {:ok, bound}

          error ->
            error
        end
      end)
    else
      false -> {:error, :webhook_mismatch}
      nil -> {:error, :not_found}
      %InboundRoute{} -> {:error, :unauthorized}
      error -> error
    end
  end

  def bind_status_webhook(operator, tenant_id, webhook_id, secret) do
    with {:ok, connection} <- ensure_connection(operator, tenant_id),
         snapshot = configuration_snapshot(connection),
         {:ok, opts} <- snapshot.management,
         {:ok, remote} <- provider().get_webhook(String.trim(webhook_id), opts),
         true <- valid_status_webhook?(remote, connection),
         {:ok, ciphertext} <- encrypt_secret(secret, secret_context(connection, "status_secret")) do
      mutate(operator, tenant_id, fn ->
        current_configuration!(tenant_id, snapshot)
        |> Ecto.Changeset.change(
          status_webhook_id: remote["id"],
          status_secret_ciphertext: ciphertext,
          last_status_event_at: nil,
          last_reply_delivered_at: nil
        )
        |> Repo.update()
      end)
    else
      false -> {:error, :webhook_mismatch}
      error -> error
    end
  end

  defp valid_inbound_webhook?(remote, route) do
    live_webhook?(remote) and remote["scope"] == "route" and
      remote["url"] == InboundRoutes.callback_url(route) and
      "message.inbound" in (remote["events"] || []) and
      route.lettermint_route_id in (remote["route_ids"] || [remote["route_id"]])
  end

  defp valid_status_webhook?(remote, connection) do
    live_webhook?(remote) and remote["url"] == status_callback_url(connection) and
      remote["scope"] == "project" and connection.project_id in (remote["project_ids"] || []) and
      Enum.all?(@status_events, &(&1 in (remote["events"] || [])))
  end

  defp live_webhook?(remote) do
    is_binary(remote["id"]) and remote["id"] != "" and remote["enabled"] == true and
      remote["delivery_mode_filter"] in ["live", "both"] and remote["has_basic_auth"] == false
  end

  def status_callback_url(connection),
    do:
      CustyardWeb.Endpoint.url() <>
        "/api/webhook/email-status/lettermint/" <> connection.status_callback_token

  def status_connection(callback_token) when is_binary(callback_token),
    do: Repo.get_by(EmailConnection, status_callback_token: callback_token)

  def status_connection(_), do: nil

  def inbound_secret(%InboundRoute{webhook_secret_ciphertext: ciphertext} = route)
      when is_binary(ciphertext),
      do: Credentials.decrypt(ciphertext, route_context(route))

  def inbound_secret(_), do: {:error, :not_configured}

  def status_secret(%EmailConnection{} = connection),
    do:
      Credentials.decrypt(
        connection.status_secret_ciphertext,
        secret_context(connection, "status_secret")
      )

  @doc "Capture freshness before dispatch; only live provider deliveries can prove receiving."
  def inbound_observation(route, normalized, params) do
    id = get_in(normalized, [:metadata, :provider_delivery_id])

    eligible =
      is_binary(route.webhook_secret_ciphertext) and
        params["event"] == "message.inbound" and params["sandbox"] == false and
        get_in(normalized, [:metadata, :is_spam]) != true and
        is_binary(id) and
        not Repo.exists?(from(m in Custyard.Message, where: m.provider_delivery_id == ^id))

    %{eligible?: eligible, provider_delivery_id: id}
  end

  @doc "Record a newly stored customer email, never triage notices or a repeated webhook."
  def record_inbound(route, conversation, normalized, %{eligible?: true, provider_delivery_id: id}) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(c in EmailConnection,
          where: c.tenant_id == ^route.tenant_id,
          update: [set: [updated_at: c.updated_at]]
        ),
        []
      )

      do_record_inbound(route, conversation, normalized, id)
    end)

    :ok
  end

  def record_inbound(_route, _conversation, _normalized, _observation), do: :ok

  defp do_record_inbound(route, conversation, normalized, id) do
    with %{webhook_secret_ciphertext: secret} <- Repo.get(InboundRoute, route.id),
         true <- secret == route.webhook_secret_ciphertext,
         %{tenant_id: tenant_id, suspect: false} <-
           Repo.get(Custyard.Conversation, conversation.id),
         true <- tenant_id == route.tenant_id,
         %Custyard.Message{} = message <-
           Repo.one(
             from(m in Custyard.Message,
               join: c in Custyard.InboundChannel,
               on: c.id == m.inbound_channel_id,
               where: m.provider_delivery_id == ^id and m.conversation_id == ^conversation.id,
               where:
                 m.source == :email and m.origin == :lettermint and m.triage_class == :customer,
               where: is_nil(m.deleted_at) and m.is_internal_note == false,
               where:
                 c.tenant_id == ^tenant_id and c.inbound_route_id == ^route.id and
                   c.state == :active
             )
           ) do
      observed = now()

      evidence = [
        last_signed_inbound_at: observed,
        latest_received_conversation_id: conversation.id
      ]

      evidence =
        if returning_reply?(message, normalized),
          do: Keyword.put(evidence, :last_returning_reply_at, observed),
          else: evidence

      Repo.update_all(from(r in InboundRoute, where: r.id == ^route.id),
        set: [webhook_verified_at: observed]
      )

      Repo.update_all(from(c in EmailConnection, where: c.tenant_id == ^tenant_id), set: evidence)
      broadcast(tenant_id)
    end

    :ok
  end

  defp returning_reply?(message, normalized) do
    references =
      [normalized[:in_reply_to], normalized[:references]]
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&String.split/1)
      |> Enum.map(&ThreadHeaders.normalize_msg_id/1)
      |> Enum.reject(&is_nil/1)

    Repo.exists?(
      from(m in Custyard.Message,
        join: c in assoc(m, :conversation),
        join: connection in EmailConnection,
        on: connection.tenant_id == c.tenant_id,
        where: m.conversation_id == ^message.conversation_id and m.id < ^message.id,
        where: m.id > connection.reply_evidence_after_message_id,
        where: m.message_id in ^references and m.source == :operator,
        where: m.delivery_status in [:sent, :delivered] and not is_nil(m.lettermint_message_id),
        where: is_nil(m.deleted_at) and m.is_internal_note == false,
        where: is_nil(m.triage_class)
      )
    )
  end

  def invalidate_receiving(tenant_id) do
    Repo.update_all(from(c in EmailConnection, where: c.tenant_id == ^tenant_id),
      set: [
        last_signed_inbound_at: nil,
        latest_received_conversation_id: nil,
        last_returning_reply_at: nil
      ]
    )

    Repo.update_all(from(r in InboundRoute, where: r.tenant_id == ^tenant_id),
      set: [webhook_verified_at: nil]
    )

    broadcast(tenant_id)
    :ok
  end

  @doc "Reset roundtrip evidence when the sending identity or credentials change."
  def invalidate_identity(tenant_id) do
    Repo.transaction(fn ->
      case do_ensure_connection(tenant_id) do
        {:ok, _connection} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      Repo.update_all(from(c in EmailConnection, where: c.tenant_id == ^tenant_id),
        set: [
          last_reply_accepted_at: nil,
          last_reply_delivered_at: nil,
          last_returning_reply_at: nil,
          reply_evidence_after_message_id: message_high_water_mark()
        ]
      )

      invalidate_receiving(tenant_id)
    end)

    :ok
  end

  defp message_high_water_mark, do: Repo.aggregate(Custyard.Message, :max, :id) || 0

  def record_reply_accepted(%{lettermint_message_id: id} = message)
      when is_binary(id) and id != "" do
    message = Repo.preload(message, :conversation)
    record_reply_evidence(message.conversation.tenant_id, :last_reply_accepted_at, message.id)
  end

  def record_reply_accepted(_message), do: :ok

  def record_status_event(connection, params, message) do
    if params["sandbox"] == false do
      record(connection.tenant_id, :last_status_event_at)

      recipient = get_in(params, ["data", "recipient"])

      primary? =
        recipient in [nil, ""] or
          DeliveryStatus.recipient_role(message, recipient) == :to

      if params["event"] == "message.delivered" and message.delivery_status == :delivered and
           primary?,
         do: record_reply_evidence(connection.tenant_id, :last_reply_delivered_at, message.id)
    end

    :ok
  end

  def status_message_belongs?(connection, %{"data" => %{"message_id" => id}}) do
    Repo.exists?(
      from(m in Custyard.Message,
        join: c in assoc(m, :conversation),
        where: m.lettermint_message_id == ^id and c.tenant_id == ^connection.tenant_id
      )
    )
  end

  def status_message_belongs?(_, _), do: false

  def legacy_status_allowed?(%{"data" => %{"message_id" => id}}) do
    tenant_id =
      Repo.one(
        from(m in Custyard.Message,
          join: c in assoc(m, :conversation),
          where: m.lettermint_message_id == ^id,
          select: c.tenant_id,
          limit: 1
        )
      )

    is_nil(tenant_id) or default_tenant?(tenant_id)
  end

  def legacy_status_allowed?(_), do: true

  defp record_reply_evidence(nil, _field, _message_id), do: :ok

  defp record_reply_evidence(tenant_id, field, message_id) do
    Repo.update_all(
      from(c in EmailConnection,
        where: c.tenant_id == ^tenant_id and c.reply_evidence_after_message_id < ^message_id
      ),
      set: [{field, now()}]
    )

    broadcast(tenant_id)
    :ok
  end

  defp record(nil, _field), do: :ok

  defp record(tenant_id, field) do
    Repo.update_all(from(c in EmailConnection, where: c.tenant_id == ^tenant_id),
      set: [{field, now()}]
    )

    broadcast(tenant_id)
    :ok
  end

  defp broadcast(tenant_id),
    do:
      Phoenix.PubSub.broadcast(Custyard.PubSub, "email_setup:#{tenant_id}", :email_setup_updated)

  def management_config(tenant_id) do
    connection = connection(tenant_id)

    with {:ok, token} <- credential(connection, tenant_id, "team_token") do
      {:ok,
       Keyword.merge(api_options(),
         team_token: token,
         project_id: connection && connection.project_id
       )}
    end
  end

  def sending_config(tenant_id) do
    connection = connection(tenant_id)

    case credential(connection, tenant_id, "project_token") do
      {:ok, token} ->
        {:ok,
         [
           adapter: Swoosh.Adapters.Lettermint,
           api_token: token,
           base_url: api_options()[:api_url]
         ]}

      {:error, :not_configured} = error ->
        if default_tenant?(tenant_id),
          do: {:ok, Application.get_env(:custyard, Custyard.Mailer, [])},
          else: error

      error ->
        error
    end
  end

  defp credential(connection, tenant_id, field) do
    ciphertext =
      connection && Map.get(connection, String.to_existing_atom(field <> "_ciphertext"))

    cond do
      is_binary(ciphertext) -> Credentials.decrypt(ciphertext, secret_context(connection, field))
      default_tenant?(tenant_id) -> env_credential(field)
      true -> {:error, :not_configured}
    end
  end

  defp env_credential("team_token") do
    case Application.get_env(:custyard, :lettermint, [])[:team_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_configured}
    end
  end

  defp env_credential("project_token") do
    case Application.get_env(:custyard, Custyard.Mailer, [])[:api_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_configured}
    end
  end

  def default_tenant?(nil), do: false

  def default_tenant?(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %{slug: "default"} -> true
      _ -> false
    end
  end

  def project_id(tenant_id) do
    case connection(tenant_id) do
      %{project_id: id} -> id
      _ -> nil
    end
  end

  def routes(tenant_id),
    do:
      Repo.all(
        from(r in InboundRoute,
          where: r.tenant_id == ^tenant_id and r.source == :lettermint,
          order_by: r.id
        )
      )

  def channels(tenant_id),
    do:
      Repo.all(
        from(c in Custyard.InboundChannel,
          where: c.tenant_id == ^tenant_id,
          preload: [:inbound_route],
          order_by: c.id
        )
      )

  def error_message(reason) do
    case check_status(reason) do
      "unauthorized" -> "The provider rejected this credential. Check the token type and value."
      "forbidden" -> "The Team token needs permission to read this provider resource."
      "unavailable" -> "The provider could not be reached. Try the check again."
      _ -> specific_error(reason)
    end
  end

  defp specific_error({:error, reason}), do: specific_error(reason)
  defp specific_error(:not_configured), do: "Finish email credentials first."

  defp specific_error(:unauthorized),
    do: "Only this tenant's administrator can change email setup."

  defp specific_error(:stale_configuration),
    do:
      "Email setup changed while this check was running. Review the current settings and try again."

  defp specific_error(:encryption_unavailable),
    do: "Ask the installation administrator to configure credential encryption."

  defp specific_error(:webhook_mismatch),
    do:
      "Check the webhook URL, scope, events and enabled state. Allow live deliveries and leave Basic Auth off."

  defp specific_error(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :project_id),
      do:
        "Choose a project before connecting routes. A connected project cannot be changed in this setup.",
      else: "The setup could not be saved. Check the supplied values."
  end

  defp specific_error(:wrong_project_or_route),
    do: "Choose an inbound route from the selected Lettermint project with a receiving domain."

  defp specific_error(:secret_required),
    do: "Enter the signing secret shown when this webhook was created."

  defp specific_error(:no_default_channel),
    do: "Choose an active support address belonging to this tenant."

  defp specific_error(_),
    do: "The setup could not be saved. Check the selected project, route and webhook."

  defp check_status(:ok), do: "verified"
  defp check_status({:error, {:provider_status, 401}}), do: "unauthorized"
  defp check_status({:error, {:provider_status, 403}}), do: "forbidden"

  defp check_status({:error, {:api_error, status, _}}),
    do: check_status({:error, {:provider_status, status}})

  defp check_status({:error, :provider_unavailable}), do: "unavailable"
  defp check_status(_), do: "incomplete"

  defp encrypt_inputs(connection, attrs, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case normalize_secret_input(Map.get(attrs, field, "")) do
        :invalid ->
          {:halt, {:error, :secret_required}}

        "" ->
          {:cont, {:ok, acc}}

        value ->
          case encrypt_secret(value, secret_context(connection, field)) do
            {:ok, ciphertext} ->
              {:cont,
               {:ok, Map.put(acc, String.to_existing_atom(field <> "_ciphertext"), ciphertext)}}

            error ->
              {:halt, error}
          end
      end
    end)
  end

  defp normalize_secret_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_secret_input(_), do: :invalid

  defp encrypt_secret(secret, context) when is_binary(secret) do
    if String.trim(secret) == "" do
      {:error, :secret_required}
    else
      case Credentials.encrypt(String.trim(secret), context) do
        {:ok, ciphertext} -> {:ok, ciphertext}
        _ -> {:error, :encryption_unavailable}
      end
    end
  end

  defp encrypt_secret(_, _), do: {:error, :secret_required}

  defp authorize(%OperatorAccount{} = operator, tenant_id) do
    current = Repo.get(OperatorAccount, operator.id)

    if current && authorized?(current, tenant_id) &&
         OperatorAccount.session_claim_matches?(current, operator.session_claim),
       do: :ok,
       else: {:error, :unauthorized}
  end

  defp authorize(_, _), do: {:error, :unauthorized}

  # Provider reads happen outside the transaction. Every local write rechecks
  # current authority under the same lock used by staff removal/reassignment.
  defp mutate(operator, tenant_id, fun) do
    Repo.transaction(fn ->
      current = OperatorAccess.lock_current(operator)

      unless current && authorized?(current, tenant_id) &&
               OperatorAccount.session_claim_matches?(current, operator.session_claim),
             do: Repo.rollback(:unauthorized)

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp configuration_snapshot(connection) do
    %{
      fields:
        Map.take(connection, [
          :id,
          :project_id,
          :project_token_ciphertext,
          :team_token_ciphertext,
          :status_webhook_id,
          :status_secret_ciphertext,
          :status_callback_token,
          :default_channel_id
        ]),
      management: management_config(connection.tenant_id),
      sending: sending_config(connection.tenant_id)
    }
  end

  defp current_configuration!(tenant_id, snapshot) do
    current = connection(tenant_id)

    if is_nil(current) or configuration_snapshot(current) != snapshot,
      do: Repo.rollback(:stale_configuration)

    current
  end

  defp current_route!(route) do
    current = Repo.get(InboundRoute, route.id)

    fields = [
      :tenant_id,
      :lettermint_route_id,
      :callback_token,
      :lettermint_webhook_id,
      :webhook_secret_ciphertext
    ]

    if is_nil(current) or Map.take(current, fields) != Map.take(route, fields),
      do: Repo.rollback(:stale_configuration)

    current
  end

  defp secret_context(connection, field), do: "email_connection:#{connection.tenant_id}:#{field}"
  defp route_context(route), do: "inbound_route:#{route.tenant_id}:#{route.id}:webhook_secret"
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp provider, do: Application.get_env(:custyard, :lettermint_setup_client, HttpClient)

  defp api_options,
    do: [
      api_url:
        Application.get_env(:custyard, :lettermint, [])[:api_url] ||
          "https://api.lettermint.co/v1"
    ]
end

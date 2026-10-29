defmodule Custyard.Acknowledgments do
  @moduledoc "Stores immutable Colonel evidence and explicit organization mappings. Callers authorize staff reads."
  import Ecto.Query

  alias Custyard.{
    StaffAccess,
    StaffAccount,
    StaffAccounts,
    Organization,
    Repo,
    Scope,
    Tenant
  }

  alias Custyard.Acknowledgments.{
    Acknowledgment,
    Audit,
    Config,
    Consumer,
    Evidence,
    Integration,
    LocalAuthority,
    OrganizationBinding,
    Subscriptions
  }

  defp subscription_status_for_tenant(tenant_id) do
    case Config.mode(Config.load(tenant_id)) do
      :disabled -> :disabled
      :configured -> Consumer.status(tenant_id)
      _ -> :not_configured
    end
  end

  @doc """
  `:disabled`, `:not_configured`, `:connecting` or `:connected`. Reads published
  state only, so it never waits on the consumer.
  """
  def subscription_status(%Scope{} = scope) do
    if administrator?(scope),
      do: subscription_status_for_tenant(scope.tenant_id),
      else: {:error, :unauthorized}
  end

  @doc """
  What the staff UI may show about the subscription. Deliberately excludes
  the URL: the map is assigned to LiveView sockets.
  """
  def subscription_overview(%Scope{tenant_id: tenant_id} = scope) do
    if administrator?(scope), do: overview(tenant_id), else: {:error, :unauthorized}
  end

  defp overview(tenant_id) do
    config = Config.load(tenant_id)

    %{
      status: subscription_status_for_tenant(tenant_id),
      broker_configured?: Config.connection_mode(config) == :configured,
      source: present(config[:source]),
      queue: config[:queue],
      prefetch: config[:prefetch],
      required_fields: [:source, :url, :queue]
    }
  end

  @doc "The configured source when it is a valid identity, for source-pinned binding."
  def configured_source(%Scope{tenant_id: tenant_id} = scope) do
    if administrator?(scope) do
      source = Config.load(tenant_id)[:source]
      if Evidence.valid_identity?(source), do: source
    end
  end

  defp administrator?(scope),
    do: match?(%StaffAccount{role: "admin"}, Scope.current_staff(scope))

  def configure_integration(%Scope{tenant_id: tenant_id} = scope, attrs) do
    case with_administrator(scope, fn -> do_configure_integration(tenant_id, attrs) end) do
      {:ok, integration} ->
        Subscriptions.refresh(tenant_id)
        {:ok, integration}

      error ->
        error
    end
  end

  defp do_configure_integration(tenant_id, attrs) do
    submitted_url = attrs[:url] || attrs["url"]

    url =
      if is_binary(submitted_url) and String.trim(submitted_url) != "",
        do: submitted_url,
        else: Config.load(tenant_id)[:url]

    with url when is_binary(url) <- url,
         :ok <- validate_integration(tenant_id, attrs, url),
         {:ok, encrypted} <- Custyard.Credentials.encrypt(url, "acknowledgments.#{tenant_id}.url") do
      attrs =
        Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
        |> Map.drop(["url"])
        |> Map.put("url_ciphertext", encrypted)
        |> Map.put("tenant_id", tenant_id)

      existing =
        Repo.get_by(Integration, tenant_id: tenant_id) ||
          %Integration{}

      case existing
           |> Integration.changeset(attrs)
           |> Repo.insert_or_update() do
        {:ok, integration} ->
          {:ok, integration}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp validate_integration(tenant_id, attrs, url) do
    config =
      Config.load(tenant_id)
      |> Keyword.merge(
        url: url,
        source: attrs[:source] || attrs["source"],
        queue: attrs[:queue] || attrs["queue"]
      )

    Config.validate!(config)
    :ok
  rescue
    ArgumentError -> {:error, :invalid_config}
  end

  @doc "Idempotently bind external evidence inside an authenticated tenant scope or explicit local capability."
  def bind(%Scope{tenant_id: tenant_id} = scope, source, external_id, organization_id) do
    with_administrator(scope, fn ->
      do_bind(tenant_id, source, external_id, organization_id, Scope.current_staff(scope))
    end)
  end

  def bind(%LocalAuthority{} = authority, source, external_id, organization_id) do
    case authorize(authority) do
      {:ok, tenant_id, actor} -> do_bind(tenant_id, source, external_id, organization_id, actor)
      error -> error
    end
  end

  def bind(_, _, _, _), do: {:error, :unauthorized}

  @doc false
  def authorize(%Scope{tenant_id: tenant_id} = scope) do
    case Scope.current_staff(scope) do
      %StaffAccount{role: "admin"} = staff -> {:ok, tenant_id, staff}
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(%LocalAuthority{tenant_id: tenant_id, channel: channel})
      when is_integer(tenant_id) and channel in ["cli", "mix", "console"] do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{status: "active"} -> {:ok, tenant_id, channel}
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_), do: {:error, :unauthorized}

  defp with_administrator(%Scope{} = scope, fun) do
    Repo.transaction(fn ->
      StaffAccess.lock_current(%StaffAccount{id: scope.staff_id})

      case Scope.current_staff(scope) do
        %StaffAccount{role: "admin"} ->
          case fun.() do
            {:error, reason} -> Repo.rollback(reason)
            result -> result
          end

        _ ->
          Repo.rollback(:unauthorized)
      end
    end)
    |> case do
      {:ok, result} -> result
      error -> error
    end
  end

  defp do_bind(tenant_id, source, external_id, organization_id, actor) do
    if !Audit.actor?(actor), do: raise(ArgumentError, "unknown audit actor")

    changeset =
      OrganizationBinding.changeset(%OrganizationBinding{}, %{
        tenant_id: tenant_id,
        source: source,
        source_organization_id: external_id,
        organization_id: organization_id
      })

    cond do
      not changeset.valid? ->
        {:error, changeset}

      # ecto_sqlite3 reports a foreign key violation without a constraint
      # name, so foreign_key_constraint/2 cannot turn it into an error.
      not organization_exists?(tenant_id, Ecto.Changeset.get_field(changeset, :organization_id)) ->
        {:error, :organization_not_found}

      true ->
        insert_binding(changeset, actor)
    end
  end

  defp insert_binding(changeset, actor) do
    Repo.transaction(fn ->
      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:tenant_id, :source, :source_organization_id]
           ) do
        {:ok, %OrganizationBinding{id: id} = binding} when not is_nil(id) ->
          Audit.record!(
            binding.tenant_id,
            :acknowledgment_binding_created,
            actor,
            binding.organization_id,
            %{
              "source" => binding.source,
              "source_organization_id" => binding.source_organization_id,
              "organization_id" => binding.organization_id
            }
          )

          {:created, binding}

        {:ok, _} ->
          existing(changeset)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {outcome, binding}} -> {:ok, outcome, binding}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.ConstraintError -> {:error, :organization_not_found}
  end

  defp existing(changeset) do
    source = Ecto.Changeset.get_field(changeset, :source)
    external_id = Ecto.Changeset.get_field(changeset, :source_organization_id)
    binding = lookup_binding(Ecto.Changeset.get_field(changeset, :tenant_id), source, external_id)

    if binding.organization_id == Ecto.Changeset.get_field(changeset, :organization_id),
      do: {:existing, binding},
      else: Repo.rollback(:conflicting_binding)
  end

  # An id beyond signed 64 bits would make the SQLite driver raise.
  defp organization_exists?(tenant_id, id) do
    StaffAccounts.valid_id?(id) and
      Repo.exists?(from o in Organization, where: o.id == ^id and o.tenant_id == ^tenant_id)
  end

  defp lookup_binding(tenant_id, source, external_id),
    do:
      Repo.get_by(OrganizationBinding,
        tenant_id: tenant_id,
        source: source,
        source_organization_id: external_id
      )

  def get_binding(%Scope{tenant_id: tenant_id} = scope, source, external_id) do
    if administrator?(scope), do: lookup_binding(tenant_id, source, external_id)
  end

  @doc "Tenant bindings with customer names for an active administrator."
  def list_bindings(%Scope{tenant_id: tenant_id} = scope) do
    if administrator?(scope) do
      Repo.all(
        from b in binding_rows(),
          where: b.tenant_id == ^tenant_id,
          order_by: [asc: b.source, asc: b.source_organization_id]
      )
    else
      []
    end
  end

  def list_bindings_for_organization(%Scope{tenant_id: tenant_id} = scope, organization_id) do
    if Scope.current_staff(scope) do
      Repo.all(
        from b in binding_rows(),
          where: b.tenant_id == ^tenant_id and b.organization_id == ^organization_id,
          order_by: [asc: b.source, asc: b.source_organization_id]
      )
    else
      []
    end
  end

  # Selects the organization's name only, never the struct with its portal token.
  defp binding_rows do
    from b in OrganizationBinding,
      join: o in assoc(b, :organization),
      select: %{
        id: b.id,
        tenant_id: b.tenant_id,
        source: b.source,
        source_organization_id: b.source_organization_id,
        organization_id: b.organization_id,
        organization_name: o.name,
        organization_public_id: o.public_id,
        inserted_at: b.inserted_at
      }
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  def list_for_organization(%Scope{tenant_id: tenant_id} = scope, id, opts \\ []) do
    if Scope.current_staff(scope) do
      limit = Keyword.get(opts, :limit, 20) |> max(1) |> min(100)
      offset = Keyword.get(opts, :offset, 0) |> max(0)

      Repo.all(
        from a in Acknowledgment,
          where: a.tenant_id == ^tenant_id and a.organization_id == ^id,
          order_by: [desc: a.received_at, desc: a.id],
          limit: ^limit,
          offset: ^offset
      )
    else
      []
    end
  end

  def ingest(tenant_id, payload) do
    with %Custyard.Tenant{status: "active"} <- Repo.get(Custyard.Tenant, tenant_id),
         {:ok, evidence} <- Evidence.validate(payload) do
      attrs = Map.put(evidence, :tenant_id, tenant_id)

      case Repo.get_by(Acknowledgment,
             tenant_id: tenant_id,
             source: attrs.source,
             submission_id: attrs.submission_id
           ) do
        nil -> insert(attrs)
        record -> compare(record, attrs)
      end
    else
      nil ->
        {:error, :tenant_suspended}

      %Custyard.Tenant{} ->
        Custyard.AuditEvent.create(%{
          tenant_id: tenant_id,
          event_type: :webhook_error,
          source: "acknowledgments",
          payload: %{"reason" => "tenant_suspended"}
        })

        {:error, :tenant_suspended}

      error ->
        error
    end
  end

  defp insert(attrs) do
    case lookup_binding(attrs.tenant_id, attrs.source, attrs.source_organization_id) do
      nil ->
        {:error, :unmapped_organization}

      binding ->
        changeset =
          Acknowledgment.changeset(
            %Acknowledgment{},
            Map.merge(attrs, %{
              organization_id: binding.organization_id,
              received_at: DateTime.utc_now()
            })
          )

        case Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:tenant_id, :source, :submission_id]
             ) do
          {:ok, _} ->
            Repo.get_by!(Acknowledgment,
              tenant_id: attrs.tenant_id,
              source: attrs.source,
              submission_id: attrs.submission_id
            )
            |> compare(attrs)

          error ->
            error
        end
    end
  end

  defp compare(record, attrs) do
    if Enum.all?(attrs, fn {key, value} -> Map.fetch!(record, key) === value end),
      do: {:ok, record},
      else: {:error, :conflicting_submission}
  end
end

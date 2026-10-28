defmodule Custyard.Notifications.TenantDelivery do
  @moduledoc false
  import Ecto.Query
  require Logger
  alias Custyard.{OperatorAccount, Repo}
  alias Custyard.Intake.EmailBranding

  def recipients(id) do
    Repo.all(
      from o in OperatorAccount,
        where: o.tenant_id == ^id and o.role in ["admin", "agent"],
        select: o.email,
        order_by: o.id
    )
  end

  def ready?(id) do
    case settings(id) do
      {:ok, _, _} -> :ok
      {:error, reason} -> skip(id, reason)
    end
  end

  def deliver(email, id) do
    case settings(id) do
      {:ok, recipients, delivery} ->
        email =
          %{email | to: [], cc: [], bcc: []}
          |> Swoosh.Email.to(recipients)
          |> EmailBranding.put_sender(EmailBranding.for_tenant(id), delivery)

        Custyard.Mailer.deliver(email, delivery.config)

      {:error, reason} ->
        skip(id, reason)
    end
  end

  defp settings(id) do
    case {Repo.get(Custyard.Tenant, id), recipients(id)} do
      {%Custyard.Tenant{status: "active"}, []} ->
        {:error, :no_staff}

      {%Custyard.Tenant{status: "active"}, recipients} ->
        case EmailBranding.delivery_settings(id) do
          {:ok, delivery} -> {:ok, recipients, delivery}
          {:error, _} -> {:error, :not_configured}
        end

      _ ->
        {:error, :tenant_suspended}
    end
  end

  defp skip(id, reason) do
    Logger.info("tenant_notification_skipped", tenant_id: id, reason: reason)
    {:error, reason}
  end
end

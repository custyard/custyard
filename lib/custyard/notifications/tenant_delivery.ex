defmodule Custyard.Notifications.TenantDelivery do
  @moduledoc false
  import Ecto.Query
  require Logger
  alias Custyard.{OperatorAccount, Repo}
  alias Custyard.Intake.EmailBranding

  def recipients(id) when id in [nil, 1],
    do: [Application.get_env(:custyard, :operator_email, "operator@example.com")]

  def recipients(id) do
    Repo.all(
      from o in OperatorAccount,
        where: o.tenant_id == ^id and o.role in ["admin", "agent"],
        select: o.email,
        order_by: o.id
    )
  end

  def ready?(id) when id in [nil, 1], do: :ok

  def ready?(id) do
    case settings(id) do
      {:ok, _, _} -> :ok
      {:error, reason} -> skip(id, reason)
    end
  end

  def deliver(email, id) when id in [nil, 1] do
    with {:ok, delivery} <- EmailBranding.delivery_settings(id) do
      Custyard.Mailer.deliver(email, delivery.config)
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
    case recipients(id) do
      [] ->
        {:error, :no_staff}

      recipients ->
        case EmailBranding.delivery_settings(id) do
          {:ok, delivery} -> {:ok, recipients, delivery}
          {:error, _} -> {:error, :not_configured}
        end
    end
  end

  defp skip(id, reason) do
    Logger.info("tenant_notification_skipped", tenant_id: id, reason: reason)
    {:error, reason}
  end
end

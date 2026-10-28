defmodule Custyard.Lettermint.DisabledClient do
  @moduledoc "Unavailable provider connection. Never manufactures remote resources."
  @behaviour Custyard.Lettermint.Client

  @impl true
  def create_route(_params), do: {:error, :not_configured}
  @impl true
  def get_route(_id), do: {:error, :not_configured}
  @impl true
  def delete_route(_id), do: {:error, :not_configured}
  @impl true
  def set_inbound_domain(_id, _domain), do: {:error, :not_configured}
  @impl true
  def verify_inbound_domain(_id), do: {:error, :not_configured}
  @impl true
  def list_domains, do: {:error, :not_configured}
  @impl true
  def get_sending_domain(_domain), do: {:error, :not_configured}
  @impl true
  def get_webhook_delivery(_id, _delivery_id), do: {:error, :not_configured}
end

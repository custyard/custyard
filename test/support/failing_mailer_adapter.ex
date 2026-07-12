defmodule Custyard.FailingMailerAdapter do
  @moduledoc """
  Swoosh adapter that fails every delivery.

  Tests swap it in (`Application.put_env(:custyard, Custyard.Mailer,
  adapter: Custyard.FailingMailerAdapter)`) to exercise mailer-failure
  paths — e.g. that a failed claim-confirmation send leaves the claim
  intact and re-sendable.
  """

  use Swoosh.Adapter

  def deliver(_email, _config), do: {:error, :smtp_down}

  def deliver_many(_emails, _config), do: {:error, :smtp_down}
end

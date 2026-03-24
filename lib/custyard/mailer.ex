defmodule Custyard.Mailer do
  @moduledoc """
  Mailer module for sending emails via Swoosh.

  Uses adapter configuration from application config.
  In dev/test, uses the Local adapter for easy testing.
  In production, configure via MAIL_* environment variables.
  """

  use Swoosh.Mailer, otp_app: :custyard
end

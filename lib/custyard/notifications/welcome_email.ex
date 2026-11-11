defmodule Custyard.Notifications.WelcomeEmail do
  @moduledoc """
  The mail `Custyard.Boot.FirstRun` sends once, to the instance administrator
  the boot just created from `INSTANCE_ADMIN_EMAIL`.

  It is the mail check: it goes through the real adapter, so an unverified
  sender is rejected here, on the first-run card, instead of as a login
  link that never arrives. It carries no login link (those expire) and no
  HTML, only where the instance is and how to sign in.
  """

  import Swoosh.Email

  @subject "Your Custyard is ready"

  @doc """
  `to` is the administrator's address, `host` the installation hostname (`PHX_HOST`),
  `from` is `{name, address}`.
  """
  @spec build(String.t(), String.t(), {String.t(), String.t()}) :: Swoosh.Email.t()
  def build(to, host, {from_name, from_address}) when is_binary(to) and is_binary(host) do
    new()
    |> to(to)
    |> from({from_name, from_address})
    |> subject(@subject)
    |> text_body(text(host, to))
  end

  defp text(host, to) do
    """
    Your Custyard instance at https://#{host} is set up.

    Sign in at https://#{host}/admin/login with this address (#{to}).
    There is no password: a login link is emailed to you each time you sign in.

    Once you have signed in, INSTANCE_ADMIN_EMAIL can be removed from the
    environment; the account stays. Create a tenant and its first staff account
    from the instance console.
    """
  end
end

defmodule Custyard.Notifications.WelcomeEmail do
  @moduledoc """
  The mail `Custyard.Boot.FirstRun` sends once, to the operator account the
  boot just created from `OPERATOR_EMAIL`.

  It is the mail check: it goes through the real adapter, so an unverified
  sender is rejected here, on the first-run card, instead of as a login
  link that never arrives. It carries no login link (those expire) and no
  HTML, only where the instance is and how to sign in.
  """

  import Swoosh.Email

  @subject "Your Custyard is ready"

  @doc """
  `to` is the operator's address, `host` the public hostname (`PHX_HOST`),
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

    Sign in at https://#{host}/operator/login with this address (#{to}).
    There is no password: a login link is emailed to you each time you sign in.

    Once you have signed in, OPERATOR_EMAIL can be removed from the environment;
    the account stays.
    """
  end
end

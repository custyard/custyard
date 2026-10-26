defmodule Custyard.Repo do
  use Ecto.Repo,
    otp_app: :custyard,
    adapter: Application.compile_env(:custyard, :repo_adapter, Custyard.Repo.Adapter)
end

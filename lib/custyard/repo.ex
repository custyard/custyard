defmodule Custyard.Repo do
  use Ecto.Repo,
    otp_app: :custyard,
    adapter: Application.compile_env(:custyard, :repo_adapter, Ecto.Adapters.SQLite3)
end

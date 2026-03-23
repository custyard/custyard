defmodule Custyard.Repo do
  use Ecto.Repo,
    otp_app: :custyard,
    adapter: Ecto.Adapters.SQLite3
end

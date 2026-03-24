# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Custyard.Repo.insert!(%Custyard.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Custyard.{Repo, OperatorAccount}

# Manual operator account creation for development.
#
# NOTE: In dev, the application auto-creates an operator account
# (admin@custyard.local) with a random password on each boot —
# see Custyard.Application.setup_dev_operator/0. This seed is
# only needed if you want an additional account or are running
# seeds outside the normal dev server flow.
#
# This block is skipped in non-dev environments.
if Application.get_env(:custyard, :env) == :dev do
  unless Repo.get_by(OperatorAccount, email: "admin@example.com") do
    password = :crypto.strong_rand_bytes(12) |> Base.url_encode64() |> binary_part(0, 16)

    %OperatorAccount{}
    |> OperatorAccount.changeset(%{email: "admin@example.com", password: password})
    |> Repo.insert!()

    IO.puts("Created operator: admin@example.com / #{password}")
  end
end

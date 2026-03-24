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

# Create default operator account for development
unless Repo.get_by(OperatorAccount, email: "admin@example.com") do
  %OperatorAccount{}
  |> OperatorAccount.changeset(%{email: "admin@example.com", password: "changeme123"})
  |> Repo.insert!()

  IO.puts("Created operator: admin@example.com / changeme123")
end

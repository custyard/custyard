defmodule Custyard.Migrations.LowercaseOperatorAccountEmailsTest do
  use Custyard.DataCase, async: false

  @migration Custyard.Repo.Migrations.LowercaseOperatorAccountEmails
  @path "priv/repo/migrations/20261012022249_lowercase_operator_account_emails.exs"

  # `mix test` migrates the test database first, so the module may already
  # be loaded; requiring the file again would redefine it.
  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    :ok
  end

  test "lowercases emails and keeps the owner on collision" do
    rows =
      insert_emails([
        "Ops@Example.COM",
        # Mixed-case row older than its lowercase twin: the lowercase row
        # keeps the address
        "Dup@Example.com",
        "dup@example.com",
        # Three mixed-case variants: the lowest id wins
        "Tri@Example.com",
        "TRI@example.com",
        "tri@EXAMPLE.com",
        "fine@example.com"
      ])

    migrate()

    assert emails() == %{
             rows["Ops@Example.COM"] => "ops@example.com",
             rows["Dup@Example.com"] => "Dup@Example.com",
             rows["dup@example.com"] => "dup@example.com",
             rows["Tri@Example.com"] => "tri@example.com",
             rows["TRI@example.com"] => "TRI@example.com",
             rows["tri@EXAMPLE.com"] => "tri@EXAMPLE.com",
             rows["fine@example.com"] => "fine@example.com"
           }
  end

  test "folds only ASCII letters, whatever the database locale" do
    bad = <<0xFF>> <> "Bad@Example.com"

    rows =
      insert_emails([
        "ÜNAL@BÜCHER.DE",
        # Turkish dotted capital I: locale-aware lower() maps it differently
        "İX@Example.com",
        bad
      ])

    migrate()

    assert emails() == %{
             rows["ÜNAL@BÜCHER.DE"] => "Ünal@bÜcher.de",
             rows["İX@Example.com"] => "İx@example.com",
             rows[bad] => <<0xFF>> <> "bad@example.com"
           }
  end

  # Above every real version, so the migrator does not warn that an older
  # version is running after newer ones.
  defp migrate do
    version = 99_990_000_000_000 + System.unique_integer([:positive])
    :ok = Ecto.Migrator.up(Repo, version, @migration, log: false)
  end

  defp insert_emails(emails) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for email <- emails, into: %{} do
      {1, [%{id: id}]} =
        Repo.insert_all(
          "operator_accounts",
          [%{email: email, role: "super_admin", inserted_at: now, updated_at: now}],
          returning: [:id]
        )

      {email, id}
    end
  end

  defp emails do
    Repo.all(from o in "operator_accounts", select: {o.id, o.email}) |> Map.new()
  end
end

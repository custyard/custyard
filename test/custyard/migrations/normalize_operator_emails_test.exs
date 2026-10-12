# Migrations are not compiled with the app. Load this one before the test
# module compiles; `mix test` may already have loaded it via ecto.migrate.
unless Code.ensure_loaded?(Custyard.Repo.Migrations.NormalizeOperatorEmails) do
  Code.require_file(
    "../../../priv/repo/migrations/20261012000000_normalize_operator_emails.exs",
    __DIR__
  )
end

defmodule Custyard.Migrations.NormalizeOperatorEmailsTest do
  use Custyard.DataCase, async: false

  import ExUnit.CaptureLog

  alias Custyard.OperatorAccount
  alias Custyard.Repo.Migrations.NormalizeOperatorEmails

  # A version no real migration uses; the sandbox rolls back its
  # schema_migrations row with everything else.
  @test_version 29_991_231_000_000
  @stamp "2026-01-01T00:00:00Z"

  defp insert_raw(email, role \\ "super_admin") do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO operator_accounts (email, role, inserted_at, updated_at) " <>
          "VALUES (?, ?, ?, ?) RETURNING id",
        [email, role, @stamp, @stamp]
      )

    id
  end

  defp stored(id) do
    %{rows: [[email, updated_at]]} =
      Repo.query!("SELECT email, updated_at FROM operator_accounts WHERE id = ?", [id])

    {email, updated_at}
  end

  defp migrate_up do
    Logger.put_module_level(NormalizeOperatorEmails, :info)

    try do
      capture_log(fn ->
        assert :ok = Ecto.Migrator.up(Repo, @test_version, NormalizeOperatorEmails, log: false)
      end)
    after
      Logger.delete_module_level(NormalizeOperatorEmails)
    end
  end

  test "normalizes mixed-case and padded emails, skips collision groups, leaves the rest" do
    mixed = insert_raw("Mixed.Case@Example.COM")
    padded = insert_raw("  padded@example.com ", "agent")
    unicode = insert_raw("ÉLODIE@Exemple.FR", "admin")
    already = insert_raw("already@example.com")

    # Group 1: a mixed-case row colliding with an already normalized one.
    bob_upper = insert_raw("Bob@Example.com")
    bob_lower = insert_raw("bob@example.com", "admin")

    # Group 2: two mixed-case rows that normalize to the same value.
    carol_a = insert_raw("CAROL@example.com")
    carol_b = insert_raw("Carol@Example.com", "agent")

    # Not UTF-8 text (SQLite stores a blob in a TEXT column as is).
    %{rows: [[blob]]} =
      Repo.query!(
        "INSERT INTO operator_accounts (email, role, inserted_at, updated_at) " <>
          "VALUES (X'FF41', 'agent', ?, ?) RETURNING id",
        [@stamp, @stamp]
      )

    log = migrate_up()

    assert {"mixed.case@example.com", _} = stored(mixed)
    assert {"padded@example.com", _} = stored(padded)
    assert {"élodie@exemple.fr", _} = stored(unicode)

    # Already normalized: not written at all.
    assert stored(already) == {"already@example.com", @stamp}

    # Collision groups: every member untouched.
    assert {"Bob@Example.com", @stamp} = stored(bob_upper)
    assert {"bob@example.com", @stamp} = stored(bob_lower)
    assert {"CAROL@example.com", @stamp} = stored(carol_a)
    assert {"Carol@Example.com", @stamp} = stored(carol_b)

    assert log =~ "Normalized operator email: id #{mixed}, role super_admin"
    assert log =~ "Normalized operator email: id #{padded}, role agent"
    assert log =~ "Normalized operator email: id #{unicode}, role admin"
    refute log =~ "id #{already},"

    assert log =~
             "skipped a collision group (emails equal ignoring case): ids #{bob_upper}, #{bob_lower}"

    assert log =~
             "skipped a collision group (emails equal ignoring case): ids #{carol_a}, #{carol_b}"

    assert log =~ "not UTF-8 text: ids #{blob}"

    # Ids and roles only: the log never carries the addresses.
    refute log =~ "@example.com"
    refute log =~ "Exemple"

    # Normalized rows now resolve through the same lookup login uses.
    assert Repo.get_by(OperatorAccount,
             email: OperatorAccount.normalize_email(" MIXED.case@example.com")
           )
  end

  test "agrees with OperatorAccount.normalize_email/1" do
    emails = [
      "  A@B.COM ",
      "ÀÉÎ@ÖÜ.de",
      "ẞtraße@Example.com",
      "plain@example.com",
      "\tTab@X.io\n"
    ]

    rows = emails |> Enum.with_index(1) |> Enum.map(fn {email, id} -> {id, email, "agent"} end)

    {changes, [], []} = NormalizeOperatorEmails.plan(rows)

    for {id, stored, normalized, _role} <- changes do
      assert Enum.at(emails, id - 1) == stored
      assert normalized == OperatorAccount.normalize_email(stored)
    end

    assert length(changes) == 4
  end

  test "plans a row whose normalized value equals another row's stored value as a collision" do
    rows = [
      {1, "dave@example.com", "admin"},
      {2, " Dave@Example.com", "super_admin"},
      {3, "erin@example.com", "agent"}
    ]

    assert NormalizeOperatorEmails.plan(rows) == {[], [[1, 2]], []}
  end

  test "is idempotent and down is a no-op" do
    id = insert_raw("Twice@Example.com")
    migrate_up()
    assert {"twice@example.com", updated_at} = stored(id)

    assert :ok = NormalizeOperatorEmails.normalize_emails(Repo)
    assert stored(id) == {"twice@example.com", updated_at}

    assert :ok = Ecto.Migrator.down(Repo, @test_version, NormalizeOperatorEmails, log: false)
    assert stored(id) == {"twice@example.com", updated_at}
  end

  test "an empty table is fine" do
    assert migrate_up() == ""
  end
end

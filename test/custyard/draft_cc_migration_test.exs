defmodule Custyard.DraftCcMigrationTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  defmodule Repo do
    use Ecto.Repo, otp_app: :custyard, adapter: Custyard.Repo.Adapter
  end

  setup_all do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      [{migration, _}] =
        Code.compile_file(
          Application.app_dir(
            :custyard,
            "priv/repo/migrations/20261029025000_track_draft_cc_intent.exs"
          )
        )

      %{migration: migration}
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  for backend <- [:sqlite, :turso] do
    @tag backend: backend
    test "#{backend}: migration preserves every legacy CC intent and rolls back without losing drafts",
         c do
      start_repo(c)

      Repo.query!(
        "CREATE TABLE staff_message_drafts (id INTEGER PRIMARY KEY, reply_text TEXT NOT NULL DEFAULT '', reply_cc TEXT NOT NULL DEFAULT '')"
      )

      Repo.query!(
        "INSERT INTO staff_message_drafts (id, reply_text, reply_cc) VALUES (1, 'Unsent reply', ''), (2, '', 'chosen@example.org'), (3, '', '')"
      )

      assert :ok = Ecto.Migrator.up(Repo, 20_261_029_025_000, c.migration, log: false)

      assert %{rows: [[1, 1], [2, 1], [3, 1]]} =
               Repo.query!("SELECT id, reply_cc_edited FROM staff_message_drafts ORDER BY id")

      Repo.query!("INSERT INTO staff_message_drafts (id) VALUES (4)")

      assert %{rows: [[0]]} =
               Repo.query!("SELECT reply_cc_edited FROM staff_message_drafts WHERE id = 4")

      assert :ok = Ecto.Migrator.down(Repo, 20_261_029_025_000, c.migration, log: false)

      assert %{
               rows: [
                 [1, "Unsent reply", ""],
                 [2, "", "chosen@example.org"],
                 [3, "", ""],
                 [4, "", ""]
               ]
             } = Repo.query!("SELECT * FROM staff_message_drafts ORDER BY id")
    end
  end

  defp start_repo(c) do
    path = Path.join(c.tmp_dir, "draft-intent.db")

    config =
      case c.backend do
        :sqlite ->
          [database: path]

        :turso ->
          server = start_supervised!({Custyard.TursoTestServer, database: path})
          [turso_url: Custyard.TursoTestServer.url(server)]
      end

    start_supervised!({Repo, [pool_size: 2, log: false] ++ config})
  end
end

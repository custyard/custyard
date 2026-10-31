defmodule Custyard.Migrations.NormalizeOperatorAccountEmailsUnicodeTest do
  use Custyard.DataCase, async: false

  import ExUnit.CaptureLog

  @migration Custyard.Repo.Migrations.NormalizeOperatorAccountEmailsUnicode
  @path "priv/repo/migrations/20261012051027_normalize_operator_account_emails_unicode.exs"

  # `mix test` migrates the test database first, so the module may already
  # be loaded; requiring the file again would redefine it.
  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    :ok
  end

  test "normalizes Unicode emails, keeps the owner on collision, and logs skipped rows" do
    rows =
      insert_emails([
        # Lone non-ASCII uppercase, which 20261012022249 leaves alone
        "ÜNAL@BÜCHER.DE",
        # Decomposed accent
        "José@Example.com",
        # Already normalized: owns its address
        "zoë@example.com",
        # Collides with the row above, so it is skipped
        "ZOË@Example.com",
        # Two unnormalized variants: the lower id wins
        "Ana@Example.ES",
        "ANA@example.es",
        "fine@example.com"
      ])

    log =
      capture_log([metadata: [:operator_id, :conflicting_operator_id, :reason]], fn ->
        migrate()
      end)

    assert emails() == %{
             rows["ÜNAL@BÜCHER.DE"] => "ünal@bücher.de",
             rows["José@Example.com"] => "josé@example.com",
             rows["zoë@example.com"] => "zoë@example.com",
             rows["ZOË@Example.com"] => "ZOË@Example.com",
             rows["Ana@Example.ES"] => "ana@example.es",
             rows["ANA@example.es"] => "ANA@example.es",
             rows["fine@example.com"] => "fine@example.com"
           }

    assert log =~ "operator_email_normalization_skipped"
    assert log =~ "reason=normalization_collision"

    for {skipped, owner} <- [
          {"ZOË@Example.com", "zoë@example.com"},
          {"ANA@example.es", "Ana@Example.ES"}
        ] do
      assert Enum.any?(String.split(log, "\n"), fn line ->
               String.contains?(line, "operator_id=#{rows[skipped]} ") and
                 String.contains?(line, "conflicting_operator_id=#{rows[owner]} ")
             end)
    end

    for email <- Map.keys(rows), do: refute(log =~ email)
  end

  test "leaves an email that is not valid UTF-8 alone and logs it" do
    bad = <<0xFF>> <> "Ops@example.com"
    rows = insert_emails([bad])

    log =
      capture_log([metadata: [:operator_id, :conflicting_operator_id, :reason]], fn ->
        migrate()
      end)

    assert emails() == %{rows[bad] => bad}
    assert log =~ "operator_email_normalization_skipped"
    assert log =~ "operator_id=#{rows[bad]} "
    assert log =~ "reason=invalid_utf8"
    refute log =~ bad
  end

  defp migrate do
    :ok = Ecto.Migrator.up(Repo, System.unique_integer([:positive]), @migration, log: false)
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

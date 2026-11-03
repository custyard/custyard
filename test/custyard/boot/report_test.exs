defmodule Custyard.Boot.ReportTest do
  use ExUnit.Case, async: true

  alias Custyard.Boot.{Env, Report}

  @canary "CANARY-" <> String.duplicate("z", 60)

  @full %{
    "SECRET_KEY_BASE" => @canary,
    "PHX_HOST" => "custyard.example.com",
    "MAIL_ADAPTER" => "lettermint",
    "LETTERMINT_PROJECT_TOKEN" => "lm_" <> @canary,
    "OPERATOR_EMAIL" => "ops@example.com",
    "DATABASE_URL" => "libsql://db-" <> @canary <> ".turso.io",
    "TURSO_AUTH_TOKEN" => "tok_" <> @canary,
    "CREDENTIAL_ENCRYPTION_KEY" => @canary <> "\n",
    "MAIL_ADAPTOR" => "oops_" <> @canary
  }

  describe "to_text/2" do
    test "never prints a value, lists present names and near misses" do
      env = Env.read(@full, config_env: :prod)
      text = Report.to_text(env)

      refute text =~ @canary
      refute text =~ "ops@example.com"
      assert text =~ "Custyard is not configured yet"
      assert text =~ "✗  CREDENTIAL_ENCRYPTION_KEY"
      assert text =~ "trailing newline"
      assert text =~ "9 visible · 8 of them Custyard settings"
      assert text =~ "LETTERMINT_PROJECT_TOKEN  MAIL_ADAPTER  OPERATOR_EMAIL  PHX_HOST"
      assert text =~ "MAIL_ADAPTOR (did you mean MAIL_ADAPTER)"
      assert text =~ "remote libSQL · DATABASE_URL is set, so remote libSQL"
    end

    test "zero environment shows the three problems and the SQLite default" do
      text = Report.to_text(Env.read(%{}, config_env: :prod))

      assert text =~ "✗  SECRET_KEY_BASE  missing"
      assert text =~ "✗  PHX_HOST"
      assert text =~ "✗  MAIL_ADAPTER"
      assert text =~ "SQLite file /data/custyard.db"
      assert text =~ "0 visible"
      assert text =~ "Near misses  none"
    end

    test "configured env prints warnings and the build details" do
      env =
        Env.read(
          %{
            "SECRET_KEY_BASE" => String.duplicate("s", 64),
            "PHX_HOST" => "custyard.example.com",
            "MAIL_ADAPTER" => "local"
          },
          config_env: :prod
        )

      text =
        Report.to_text(env,
          build: %{version: "0.9.3", git_sha: "7f3a2c1", built_at: ~U[2026-11-03 14:02:00Z]},
          booted_at: ~U[2026-11-03 21:14:08Z]
        )

      assert text =~ "Custyard configuration is complete"
      assert text =~ "⚠  MAIL_ADAPTER"
      assert text =~ "⚠  CREDENTIAL_ENCRYPTION_KEY"
      assert text =~ "Image        custyard 0.9.3 · git 7f3a2c1 · built 2026-11-03 14:02:00 UTC"
      assert text =~ "Booted       2026-11-03 21:14:08 UTC"
      refute text =~ "✗"
    end
  end

  describe "paste_block/1" do
    test "zero environment lists all five lines with a fresh secret" do
      block = Report.paste_block(Env.read(%{}, config_env: :prod))
      lines = String.split(block, "\n")

      assert ["SECRET_KEY_BASE=" <> secret | rest] = lines
      assert {:ok, bytes} = Base.decode64(secret)
      assert byte_size(bytes) == 64

      assert rest == [
               "PHX_HOST=‹custyard.example.com›",
               "OPERATOR_EMAIL=‹you@example.com›",
               "MAIL_ADAPTER=lettermint",
               "LETTERMINT_PROJECT_TOKEN=‹project token›"
             ]

      refute Report.paste_block(Env.read(%{}, config_env: :prod)) == block
    end

    test "omits variables that are already set" do
      env =
        Env.read(
          %{
            "SECRET_KEY_BASE" => String.duplicate("s", 64),
            "MAIL_ADAPTER" => "mailgun",
            "MAILGUN_API_KEY" => "k"
          },
          config_env: :prod
        )

      assert Report.paste_block(env) == """
             PHX_HOST=‹custyard.example.com›
             OPERATOR_EMAIL=‹you@example.com›
             MAILGUN_DOMAIN=‹mail.example.com›\
             """
    end

    test "is empty when everything is set" do
      env =
        Env.read(
          %{
            "SECRET_KEY_BASE" => String.duplicate("s", 64),
            "PHX_HOST" => "custyard.example.com",
            "OPERATOR_EMAIL" => "ops@example.com",
            "MAIL_ADAPTER" => "local"
          },
          config_env: :prod
        )

      assert Report.paste_block(env) == ""
    end
  end
end

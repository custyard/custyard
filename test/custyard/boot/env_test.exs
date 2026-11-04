defmodule Custyard.Boot.EnvTest do
  use ExUnit.Case, async: true

  alias Custyard.Boot.Env

  @secret String.duplicate("s", 64)
  @credential_key :crypto.strong_rand_bytes(32)

  @minimal %{
    "SECRET_KEY_BASE" => @secret,
    "PHX_HOST" => "custyard.example.com",
    "MAIL_ADAPTER" => "lettermint",
    "LETTERMINT_PROJECT_TOKEN" => "lm_project_token",
    "OPERATOR_EMAIL" => "ops@example.com",
    "CREDENTIAL_ENCRYPTION_KEY" => Base.encode64(@credential_key)
  }

  defp prod(env), do: Env.read(env, config_env: :prod)

  defp problems_for(%Env{problems: problems}, variable),
    do: Enum.filter(problems, &(&1.variable == variable))

  defp kinds(%Env{problems: problems}), do: Enum.map(problems, &{&1.variable, &1.kind})

  defp warning?(%Env{warnings: warnings}, variable, fragment) do
    Enum.any?(warnings, &(&1.variable == variable and String.contains?(&1.detail, fragment)))
  end

  describe "zero environment in prod" do
    setup do
      %{env: prod(%{})}
    end

    test "reports exactly the four required variables as missing", %{env: env} do
      assert env.verdict == :unconfigured

      assert kinds(env) == [
               {"SECRET_KEY_BASE", :missing},
               {"PHX_HOST", :missing},
               {"MAIL_ADAPTER", :missing},
               {"CREDENTIAL_ENCRYPTION_KEY", :missing}
             ]
    end

    test "defaults the database to the SQLite file", %{env: env} do
      assert env.settings.database == {:sqlite, "/data/custyard.db"}
      assert env.settings.database_reason =~ "SQLite file"
      assert env.settings.pool_size == 10
      assert env.settings.port == 4000
    end

    test "fills every settings key", %{env: env} do
      assert env.settings.secret_key_base == nil
      assert env.settings.host == nil
      assert env.settings.mail == nil
      assert env.settings.credential_keys == %{current: nil, previous: []}
      assert env.settings.operator_email == nil

      assert env.settings.notifications == %{
               enabled: false,
               operator_email: nil,
               from_name: "Custyard",
               from_address: nil
             }

      assert env.settings.upload_dir == "/data/uploads"
      assert env.settings.attachment_dir == "/data/attachments"
      assert env.settings.trust_proxy_headers == false
      assert env.settings.platform == :unknown
      assert env.present == []
      assert env.variable_count == 0
      assert env.near_misses == []
    end
  end

  describe "complete minimal prod environment" do
    setup do
      %{env: prod(@minimal)}
    end

    test "is configured", %{env: env} do
      assert env.verdict == :configured
      assert env.problems == []
      assert env.settings.secret_key_base == @secret
      assert env.settings.host == "custyard.example.com"
      assert env.settings.operator_email == "ops@example.com"

      assert env.settings.mail == %{
               adapter: :lettermint,
               config: [
                 adapter: Swoosh.Adapters.Lettermint,
                 api_token: "lm_project_token",
                 base_url: "https://api.lettermint.co/v1"
               ]
             }
    end

    test "decodes the credential key without warnings", %{env: env} do
      assert env.settings.credential_keys == %{current: @credential_key, previous: []}
      refute warning?(env, "CREDENTIAL_ENCRYPTION_KEY", "")
    end

    test "turns notifications on with a noreply sender", %{env: env} do
      assert env.settings.notifications == %{
               enabled: true,
               operator_email: "ops@example.com",
               from_name: "Custyard",
               from_address: "noreply@custyard.example.com"
             }
    end

    test "lists the present names sorted", %{env: env} do
      assert env.present == Enum.sort(Map.keys(@minimal))
      assert env.variable_count == 6
    end
  end

  describe "value handling" do
    test "trims whitespace and newlines with a warning" do
      env = prod(Map.put(@minimal, "PHX_HOST", "  custyard.example.com\n"))
      assert env.settings.host == "custyard.example.com"
      assert warning?(env, "PHX_HOST", "trimmed")
    end

    test "blank after trim counts as unset" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", " \n"))
      assert kinds(env) == [{"MAIL_ADAPTER", :missing}]
      refute "MAIL_ADAPTER" in env.present
    end

    test "quoted MAIL_ADAPTER is malformed, not also missing" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "\"lettermint\""))
      assert [%{kind: :malformed, detail: detail}] = problems_for(env, "MAIL_ADAPTER")
      assert detail =~ "quote characters"
      assert env.settings.mail == nil
      assert "MAIL_ADAPTER" in env.present
    end

    test "single quotes are reported the same way" do
      env = prod(Map.put(@minimal, "PHX_HOST", "'custyard.example.com'"))
      assert [%{kind: :malformed}] = problems_for(env, "PHX_HOST")
    end
  end

  describe "SECRET_KEY_BASE" do
    test "shorter than 64 bytes is malformed" do
      env = prod(Map.put(@minimal, "SECRET_KEY_BASE", "short"))
      assert [%{kind: :malformed}] = problems_for(env, "SECRET_KEY_BASE")
      assert env.settings.secret_key_base == nil
      # The credential key does not depend on SECRET_KEY_BASE.
      assert env.settings.credential_keys.current == @credential_key
    end
  end

  describe "PHX_HOST" do
    test "falls back to FLY_APP_NAME.fly.dev with a warning" do
      env = prod(@minimal |> Map.delete("PHX_HOST") |> Map.put("FLY_APP_NAME", "custyard-eu"))
      assert env.verdict == :configured
      assert env.settings.host == "custyard-eu.fly.dev"
      assert warning?(env, "PHX_HOST", "FLY_APP_NAME")
      assert env.settings.platform == :fly
      assert env.settings.trust_proxy_headers == true
      assert "FLY_APP_NAME" in env.present
    end

    test "rejects a URL" do
      env = prod(Map.put(@minimal, "PHX_HOST", "https://custyard.example.com/"))
      assert [%{kind: :malformed}] = problems_for(env, "PHX_HOST")
      assert env.settings.host == nil
      assert env.settings.notifications.from_address == nil
    end
  end

  describe "MAIL_ADAPTER" do
    test "unknown adapter is unsupported and lists the choices" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "sendmail"))
      assert [%{kind: :unsupported, detail: detail}] = problems_for(env, "MAIL_ADAPTER")
      assert detail =~ "mailgun, sendgrid, smtp, postmark, lettermint, local"
    end

    test "local warns and disables notifications by default" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "local"))
      assert env.verdict == :configured
      assert env.settings.mail == %{adapter: :local, config: [adapter: Swoosh.Adapters.Local]}
      assert warning?(env, "MAIL_ADAPTER", "discarded")
      assert env.settings.notifications.enabled == false
    end

    test "lettermint without a token is missing LETTERMINT_PROJECT_TOKEN" do
      env = prod(Map.delete(@minimal, "LETTERMINT_PROJECT_TOKEN"))
      assert [%{kind: :missing}] = problems_for(env, "LETTERMINT_PROJECT_TOKEN")
    end

    test "lettermint accepts LETTERMINT_API_KEY with a deprecation warning" do
      env =
        prod(
          @minimal
          |> Map.delete("LETTERMINT_PROJECT_TOKEN")
          |> Map.put("LETTERMINT_API_KEY", "legacy")
          |> Map.put("LETTERMINT_API_URL", "https://lm.internal/v1")
        )

      assert env.verdict == :configured
      assert env.settings.mail.config[:api_token] == "legacy"
      assert env.settings.mail.config[:base_url] == "https://lm.internal/v1"
      assert warning?(env, "LETTERMINT_API_KEY", "deprecated")
    end

    test "mailgun needs both key and domain" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "mailgun"))
      assert kinds(env) == [{"MAILGUN_API_KEY", :missing}, {"MAILGUN_DOMAIN", :missing}]

      env = prod(Map.merge(@minimal, %{"MAIL_ADAPTER" => "mailgun", "MAILGUN_API_KEY" => "k"}))
      assert kinds(env) == [{"MAILGUN_DOMAIN", :missing}]
      assert env.settings.mail.config[:adapter] == Swoosh.Adapters.Mailgun
    end

    test "sendgrid needs SENDGRID_API_KEY" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "sendgrid"))
      assert kinds(env) == [{"SENDGRID_API_KEY", :missing}]
    end

    test "postmark needs POSTMARK_API_KEY" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "postmark"))
      assert kinds(env) == [{"POSTMARK_API_KEY", :missing}]
    end

    test "smtp needs SMTP_HOST and parses port and ssl" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTER", "smtp"))
      assert kinds(env) == [{"SMTP_HOST", :missing}]
      assert env.settings.mail.config[:port] == 587
      assert env.settings.mail.config[:ssl] == false

      env =
        prod(
          Map.merge(@minimal, %{
            "MAIL_ADAPTER" => "smtp",
            "SMTP_HOST" => "smtp.example.com",
            "SMTP_PORT" => "465",
            "SMTP_SSL" => "true",
            "SMTP_USERNAME" => "u",
            "SMTP_PASSWORD" => "p"
          })
        )

      assert env.verdict == :configured

      assert env.settings.mail.config == [
               adapter: Swoosh.Adapters.SMTP,
               relay: "smtp.example.com",
               port: 465,
               username: "u",
               password: "p",
               ssl: true,
               tls: :always,
               auth: :always
             ]
    end

    test "bad SMTP_PORT is malformed and keeps the default" do
      env =
        prod(
          Map.merge(@minimal, %{
            "MAIL_ADAPTER" => "smtp",
            "SMTP_HOST" => "smtp.example.com",
            "SMTP_PORT" => "five"
          })
        )

      assert [%{kind: :malformed}] = problems_for(env, "SMTP_PORT")
      assert env.settings.mail.config[:port] == 587
    end
  end

  describe "OPERATOR_EMAIL" do
    test "must look like an address" do
      env = prod(Map.put(@minimal, "OPERATOR_EMAIL", "ops-at-example"))
      assert [%{kind: :malformed}] = problems_for(env, "OPERATOR_EMAIL")
      assert env.settings.operator_email == nil
      assert env.settings.notifications.operator_email == nil
    end

    test "OPERATOR_NOTIFICATION_EMAIL overrides for notifications" do
      env = prod(Map.put(@minimal, "OPERATOR_NOTIFICATION_EMAIL", "alerts@example.com"))
      assert env.settings.notifications.operator_email == "alerts@example.com"
      assert env.settings.operator_email == "ops@example.com"
    end
  end

  describe "database" do
    test "libsql without a token is a problem on TURSO_AUTH_TOKEN" do
      env = prod(Map.put(@minimal, "DATABASE_URL", "libsql://db-org.turso.io"))
      assert [%{kind: :missing, detail: detail}] = problems_for(env, "TURSO_AUTH_TOKEN")
      assert detail =~ "turso db tokens create"
      assert env.settings.database == {:turso, "libsql://db-org.turso.io", nil}
      assert env.settings.database_reason =~ "DATABASE_URL is set"
    end

    test "libsql with tls=0 may run without a token" do
      env = prod(Map.put(@minimal, "DATABASE_URL", "libsql://sqld.internal:8080?tls=0"))
      assert env.verdict == :configured
      assert {:turso, _, nil} = env.settings.database
    end

    test "libsql with a token" do
      env =
        prod(
          Map.merge(@minimal, %{
            "DATABASE_URL" => "libsql://db-org.turso.io",
            "TURSO_AUTH_TOKEN" => "tok"
          })
        )

      assert env.verdict == :configured
      assert env.settings.database == {:turso, "libsql://db-org.turso.io", "tok"}
    end

    test "BUNNY_DATABASE_URL and BUNNY_DATABASE_AUTH_TOKEN are fallbacks" do
      env =
        prod(
          Map.merge(@minimal, %{
            "BUNNY_DATABASE_URL" => "libsql://bunny.turso.io",
            "BUNNY_DATABASE_AUTH_TOKEN" => "bunny-tok"
          })
        )

      assert env.verdict == :configured
      assert env.settings.database == {:turso, "libsql://bunny.turso.io", "bunny-tok"}
      assert env.settings.database_reason == "BUNNY_DATABASE_URL is set, so remote libSQL"
      assert env.settings.platform == :bunny
      assert env.settings.trust_proxy_headers == false
      assert "BUNNY_DATABASE_URL" in env.present
      assert env.near_misses == []
    end

    test "postgres URLs pass through" do
      env = prod(Map.put(@minimal, "DATABASE_URL", "postgres://u:p@db/custyard"))
      assert env.verdict == :configured
      assert env.settings.database == {:postgres, "postgres://u:p@db/custyard"}
    end

    test "other schemes are malformed" do
      env = prod(Map.put(@minimal, "DATABASE_URL", "mysql://db/custyard"))
      assert [%{kind: :malformed}] = problems_for(env, "DATABASE_URL")
      assert env.settings.database == nil
    end

    test "relative DATABASE_PATH is malformed" do
      env = prod(Map.put(@minimal, "DATABASE_PATH", "custyard.db"))
      assert [%{kind: :malformed}] = problems_for(env, "DATABASE_PATH")
      assert env.settings.database == nil
    end

    test "absolute DATABASE_PATH is used" do
      env = prod(Map.put(@minimal, "DATABASE_PATH", "/var/lib/custyard.db"))
      assert env.settings.database == {:sqlite, "/var/lib/custyard.db"}
    end

    test "POOL_SIZE parses and falls back" do
      assert prod(Map.put(@minimal, "POOL_SIZE", "4")).settings.pool_size == 4

      for value <- ["many", "0", "-3"] do
        env = prod(Map.put(@minimal, "POOL_SIZE", value))
        assert [%{kind: :malformed}] = problems_for(env, "POOL_SIZE"), value
        assert env.settings.pool_size == 10
      end
    end

    test "PORT must be a positive integer" do
      assert prod(Map.put(@minimal, "PORT", "8080")).settings.port == 8080

      for value <- ["0", "-1", "http"] do
        env = prod(Map.put(@minimal, "PORT", value))
        assert [%{kind: :malformed}] = problems_for(env, "PORT"), value
        assert env.settings.port == 4000
      end
    end
  end

  describe "CREDENTIAL_ENCRYPTION_KEY" do
    test "is required in prod and never derived from SECRET_KEY_BASE" do
      env = prod(Map.delete(@minimal, "CREDENTIAL_ENCRYPTION_KEY"))
      assert env.verdict == :unconfigured
      assert [%{kind: :missing, detail: detail}] = problems_for(env, "CREDENTIAL_ENCRYPTION_KEY")
      assert detail =~ "encrypts stored tenant credentials"
      assert detail =~ "openssl rand -base64 32"
      assert env.settings.credential_keys == %{current: nil, previous: []}
      assert env.warnings == []
    end

    test "is not required outside prod" do
      env = Env.read(Map.delete(@minimal, "CREDENTIAL_ENCRYPTION_KEY"), config_env: :dev)
      assert env.verdict == :configured
      assert problems_for(env, "CREDENTIAL_ENCRYPTION_KEY") == []
      assert env.settings.credential_keys == %{current: nil, previous: []}
    end

    test "a 65-byte hex value with a trailing newline reports both facts" do
      hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      env = prod(Map.put(@minimal, "CREDENTIAL_ENCRYPTION_KEY", hex <> "\n"))

      assert [%{kind: :malformed, detail: detail}] =
               problems_for(env, "CREDENTIAL_ENCRYPTION_KEY")

      assert detail =~ "65 bytes"
      assert detail =~ "trailing newline"
      assert detail =~ "openssl rand -base64 32"
      assert env.settings.credential_keys.current == nil
      # Only the trim warning; nothing stands in for the malformed key.
      assert warning?(env, "CREDENTIAL_ENCRYPTION_KEY", "trimmed")
      assert Enum.count(env.warnings, &(&1.variable == "CREDENTIAL_ENCRYPTION_KEY")) == 1
    end

    test "a valid key is decoded to its 32 bytes" do
      key = :crypto.strong_rand_bytes(32)
      env = prod(Map.put(@minimal, "CREDENTIAL_ENCRYPTION_KEY", Base.encode64(key)))
      assert env.settings.credential_keys.current == key
      refute warning?(env, "CREDENTIAL_ENCRYPTION_KEY", "")
    end

    test "previous key is decoded into the list" do
      key = :crypto.strong_rand_bytes(32)
      old = :crypto.strong_rand_bytes(32)

      env =
        prod(
          Map.merge(@minimal, %{
            "CREDENTIAL_ENCRYPTION_KEY" => Base.encode64(key),
            "CREDENTIAL_ENCRYPTION_KEY_PREVIOUS" => Base.encode64(old)
          })
        )

      assert env.settings.credential_keys == %{current: key, previous: [old]}
    end

    test "malformed previous key is reported" do
      env = prod(Map.put(@minimal, "CREDENTIAL_ENCRYPTION_KEY_PREVIOUS", "nope"))
      assert [%{kind: :malformed}] = problems_for(env, "CREDENTIAL_ENCRYPTION_KEY_PREVIOUS")
      assert env.settings.credential_keys.previous == []
    end
  end

  describe "notifications" do
    test "EMAIL_NOTIFICATIONS_ENABLED=false turns them off" do
      env = prod(Map.put(@minimal, "EMAIL_NOTIFICATIONS_ENABLED", "false"))
      assert env.settings.notifications.enabled == false
    end

    test "non-boolean is malformed and keeps the default" do
      env = prod(Map.put(@minimal, "EMAIL_NOTIFICATIONS_ENABLED", "yes"))
      assert [%{kind: :malformed}] = problems_for(env, "EMAIL_NOTIFICATIONS_ENABLED")
      assert env.settings.notifications.enabled == true
    end

    test "explicit sender and name win" do
      env =
        prod(
          Map.merge(@minimal, %{
            "EMAIL_FROM_NAME" => "Support",
            "EMAIL_FROM_ADDRESS" => "hello@example.com"
          })
        )

      assert env.settings.notifications.from_name == "Support"
      assert env.settings.notifications.from_address == "hello@example.com"
    end
  end

  describe "acknowledgments" do
    test "ACKNOWLEDGMENTS_ENABLED must be boolean" do
      env = prod(Map.put(@minimal, "ACKNOWLEDGMENTS_ENABLED", "on"))
      assert [%{kind: :malformed}] = problems_for(env, "ACKNOWLEDGMENTS_ENABLED")
    end

    test "ACKNOWLEDGMENTS_PREFETCH must be 1..100" do
      assert prod(Map.put(@minimal, "ACKNOWLEDGMENTS_PREFETCH", "100")).problems == []
      env = prod(Map.put(@minimal, "ACKNOWLEDGMENTS_PREFETCH", "0"))
      assert [%{kind: :malformed}] = problems_for(env, "ACKNOWLEDGMENTS_PREFETCH")
    end

    test "URL and source must be set together in prod" do
      env = prod(Map.put(@minimal, "ACKNOWLEDGMENTS_AMQP_URL", "amqp://broker"))
      assert [%{kind: :missing}] = problems_for(env, "ACKNOWLEDGMENTS_SOURCE")

      env = prod(Map.put(@minimal, "ACKNOWLEDGMENTS_SOURCE", "colonel"))
      assert [%{kind: :missing}] = problems_for(env, "ACKNOWLEDGMENTS_AMQP_URL")

      env = Env.read(Map.put(@minimal, "ACKNOWLEDGMENTS_SOURCE", "colonel"), config_env: :dev)
      assert env.problems == []
    end
  end

  describe "IMAP_ENABLED" do
    test "anything but false is unsupported" do
      env = prod(Map.put(@minimal, "IMAP_ENABLED", "true"))
      assert [%{kind: :unsupported, detail: detail}] = problems_for(env, "IMAP_ENABLED")
      assert detail =~ "IMAP channel"
      assert prod(Map.put(@minimal, "IMAP_ENABLED", "false")).problems == []
    end
  end

  describe "near misses" do
    test "MAIL_ADAPTOR suggests MAIL_ADAPTER" do
      env = prod(Map.put(@minimal, "MAIL_ADAPTOR", "lettermint"))
      assert env.near_misses == [%{found: "MAIL_ADAPTOR", expected: "MAIL_ADAPTER"}]
      refute "MAIL_ADAPTOR" in env.present
    end

    test "a known name in the wrong case is a near miss" do
      env = prod(Map.put(@minimal, "phx_host", "x"))
      assert env.near_misses == [%{found: "phx_host", expected: "PHX_HOST"}]
    end

    test "ordinary shell variables are not near misses" do
      env =
        prod(
          Map.merge(@minimal, %{
            "PATH" => "/usr/bin",
            "HOME" => "/home/custyard",
            "HOSTNAME" => "abc",
            "TERM" => "xterm",
            "LANG" => "C.UTF-8",
            "RELEASE_NAME" => "custyard"
          })
        )

      assert env.near_misses == []
      assert env.variable_count == 12
    end
  end

  describe "dev and test" do
    test "nothing set is configured" do
      env = Env.read(%{}, config_env: :dev)
      assert env.verdict == :configured
      assert env.problems == []
      assert env.settings.database == {:sqlite, "/data/custyard.db"}
      assert env.settings.credential_keys == %{current: nil, previous: []}
    end

    test "shape checks still apply to set values" do
      env = Env.read(%{"PHX_HOST" => "http://x"}, config_env: :test)
      assert env.verdict == :unconfigured
      assert kinds(env) == [{"PHX_HOST", :malformed}]
    end

    test "read/0 reads the real environment without raising" do
      assert %Env{} = Env.read()
    end
  end
end

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
    "INSTANCE_ADMIN_EMAIL" => "ops@example.com",
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
      assert env.settings.instance_admin_email == nil

      assert env.settings.notifications == %{
               enabled: false,
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
      assert env.settings.instance_admin_email == "ops@example.com"

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

    test "LETTERMINT_API_KEY is no longer a sending token" do
      env =
        prod(
          @minimal
          |> Map.delete("LETTERMINT_PROJECT_TOKEN")
          |> Map.put("LETTERMINT_API_KEY", "legacy")
          |> Map.put("LETTERMINT_API_URL", "https://lm.internal/v1")
        )

      assert [%{kind: :missing}] = problems_for(env, "LETTERMINT_PROJECT_TOKEN")
      assert env.settings.mail.config[:api_token] == nil
      assert env.settings.mail.config[:base_url] == "https://lm.internal/v1"
      assert warning?(env, "LETTERMINT_API_KEY", "LETTERMINT_PROJECT_TOKEN")
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

  describe "INSTANCE_ADMIN_EMAIL" do
    test "must look like an address" do
      env = prod(Map.put(@minimal, "INSTANCE_ADMIN_EMAIL", "ops-at-example"))
      assert [%{kind: :malformed}] = problems_for(env, "INSTANCE_ADMIN_EMAIL")
      assert env.settings.instance_admin_email == nil
    end

    test "is optional and never part of the notification settings" do
      env = prod(Map.delete(@minimal, "INSTANCE_ADMIN_EMAIL"))
      assert env.problems == []
      assert env.settings.instance_admin_email == nil
      refute Map.has_key?(env.settings.notifications, :operator_email)
    end
  end

  describe "variables an earlier release read" do
    test "are warnings that say where the setting lives now, never problems" do
      retired = %{
        "OPERATOR_EMAIL" => "INSTANCE_ADMIN_EMAIL",
        "OPERATOR_NOTIFICATION_EMAIL" => "tenant",
        "ACKNOWLEDGMENTS_ENABLED" => "tenant",
        "ACKNOWLEDGMENTS_AMQP_URL" => "tenant",
        "ACKNOWLEDGMENTS_SOURCE" => "tenant",
        "ACKNOWLEDGMENTS_QUEUE" => "tenant",
        "LETTERMINT_TEAM_TOKEN" => "tenant",
        "WEBHOOK_SECRET_LETTERMINT" => "tenant"
      }

      env =
        prod(Map.merge(@minimal, Map.new(retired, fn {name, _} -> {name, "PRIVATE-VALUE"} end)))

      assert env.problems == []
      assert env.verdict == :configured

      for {name, fragment} <- retired do
        assert warning?(env, name, "no longer read")
        assert warning?(env, name, fragment)
        assert name in env.present
        refute name in Env.known_names()
      end

      refute inspect(env.warnings) =~ "PRIVATE-VALUE"
    end

    test "an absent retired variable says nothing" do
      assert prod(@minimal).warnings == []
    end
  end

  describe "outbound delivery and the attachment scanner" do
    test "delivery is on unless stopped, and a mistyped value keeps it stopped" do
      assert prod(@minimal).settings.outbound_delivery_enabled == true

      assert prod(Map.put(@minimal, "OUTBOUND_DELIVERY_ENABLED", "false")).settings.outbound_delivery_enabled ==
               false

      env = prod(Map.put(@minimal, "OUTBOUND_DELIVERY_ENABLED", "flase"))
      assert [%{kind: :malformed}] = problems_for(env, "OUTBOUND_DELIVERY_ENABLED")
      assert env.settings.outbound_delivery_enabled == false
    end

    test "the scanner is configured only with a host and values in range" do
      assert prod(@minimal).settings.attachment_scanner == nil

      env = prod(Map.put(@minimal, "CLAMAV_HOST", "scanner.internal"))
      assert env.problems == []

      assert env.settings.attachment_scanner ==
               %{host: "scanner.internal", port: 3310, timeout: 10_000}

      for {name, value} <- [
            {"CLAMAV_PORT", "70000"},
            {"CLAMAV_TIMEOUT_MS", "5"},
            {"CLAMAV_PORT", "x"}
          ] do
        env = prod(Map.merge(@minimal, %{"CLAMAV_HOST" => "scanner.internal", name => value}))
        assert [%{kind: :malformed}] = problems_for(env, name)
        assert env.settings.attachment_scanner == nil
      end
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

    test "the Bunny names select Bunny Database and its driver" do
      env =
        prod(
          Map.merge(@minimal, %{
            "BUNNY_DATABASE_URL" => "https://db-id.lite.bunnydb.net",
            "BUNNY_DATABASE_AUTH_TOKEN" => "bunny-tok"
          })
        )

      assert env.verdict == :configured
      assert env.settings.database == {:turso, "https://db-id.lite.bunnydb.net", "bunny-tok"}
      assert env.settings.turso_provider == :bunny

      assert env.settings.database_reason ==
               "BUNNY_DATABASE_URL is set, so Bunny Database (remote libSQL)"

      assert env.settings.platform == :bunny
      assert env.settings.trust_proxy_headers == false
      assert "BUNNY_DATABASE_URL" in env.present
      assert env.near_misses == []
    end

    test "a Turso database keeps the Turso driver" do
      env =
        prod(
          Map.merge(@minimal, %{
            "DATABASE_URL" => "libsql://db-org.turso.io",
            "TURSO_AUTH_TOKEN" => "tok"
          })
        )

      assert env.settings.turso_provider == :turso
      assert prod(@minimal).settings.turso_provider == nil
    end

    test "DATABASE_PROVIDER=bunny accepts the generic names and identical aliases" do
      generic = %{
        "DATABASE_PROVIDER" => "bunny",
        "DATABASE_URL" => "libsql://db-id.lite.bunnydb.net",
        "TURSO_AUTH_TOKEN" => "tok"
      }

      env = prod(Map.merge(@minimal, generic))
      assert env.verdict == :configured
      assert env.settings.database == {:turso, "libsql://db-id.lite.bunnydb.net", "tok"}
      assert env.settings.turso_provider == :bunny
      assert env.settings.database_reason =~ "DATABASE_URL is set, so Bunny Database"

      aliases = %{
        "BUNNY_DATABASE_URL" => "libsql://db-id.lite.bunnydb.net",
        "BUNNY_DATABASE_AUTH_TOKEN" => "tok"
      }

      env = prod(@minimal |> Map.merge(generic) |> Map.merge(aliases))
      assert env.verdict == :configured
      assert env.settings.turso_provider == :bunny
    end

    test "Bunny settings never fall back to the SQLite file" do
      env = prod(Map.put(@minimal, "DATABASE_PROVIDER", "bunny"))
      assert [%{kind: :missing}] = problems_for(env, "BUNNY_DATABASE_URL")
      assert env.settings.database == nil

      env = prod(Map.put(@minimal, "BUNNY_DATABASE_URL", "https://db-id.lite.bunnydb.net"))
      assert [%{kind: :missing}] = problems_for(env, "BUNNY_DATABASE_AUTH_TOKEN")
      assert env.verdict == :unconfigured
      assert {:turso, _url, nil} = env.settings.database

      env = prod(Map.put(@minimal, "BUNNY_DATABASE_AUTH_TOKEN", "orphan-token"))
      assert [%{kind: :missing}] = problems_for(env, "BUNNY_DATABASE_URL")
      assert env.settings.database == nil
    end

    test "conflicting aliases are problems that expose neither value" do
      bunny = %{
        "BUNNY_DATABASE_URL" => "https://db-id.lite.bunnydb.net",
        "BUNNY_DATABASE_AUTH_TOKEN" => "private-bunny-token"
      }

      env =
        prod(@minimal |> Map.merge(bunny) |> Map.put("DATABASE_URL", "libsql://other.invalid"))

      assert [%{kind: :malformed, detail: detail}] = problems_for(env, "BUNNY_DATABASE_URL")
      assert detail =~ "conflicts with DATABASE_URL"
      refute inspect(env.problems) =~ "other.invalid"
      refute inspect(env.problems) =~ "bunnydb.net"
      assert env.settings.database == nil

      env = prod(@minimal |> Map.merge(bunny) |> Map.put("TURSO_AUTH_TOKEN", "another-token"))

      assert [%{kind: :malformed, detail: detail}] =
               problems_for(env, "BUNNY_DATABASE_AUTH_TOKEN")

      assert detail =~ "conflicts with TURSO_AUTH_TOKEN"
      refute inspect(env.problems) =~ "another-token"
      refute inspect(env.problems) =~ "private-bunny-token"
      assert env.settings.database == nil
    end

    test "an unsafe Bunny URL is malformed and never echoed" do
      for url <- [
            "http://db.invalid",
            "libsql://db.invalid?tls=0",
            "https://user:pass@db.invalid",
            "https://db.invalid#fragment",
            "https://"
          ] do
        env =
          prod(
            Map.merge(@minimal, %{
              "BUNNY_DATABASE_URL" => url,
              "BUNNY_DATABASE_AUTH_TOKEN" => "tok"
            })
          )

        assert [%{kind: :malformed, detail: detail}] = problems_for(env, "BUNNY_DATABASE_URL"),
               url

        assert detail =~ "https:// or libsql://"
        refute inspect(env.problems) =~ "db.invalid"
        assert env.settings.database == nil
      end
    end

    test "DATABASE_PROVIDER must be a known provider and agree with the other settings" do
      env = prod(Map.put(@minimal, "DATABASE_PROVIDER", "private-invalid-provider"))
      assert [%{kind: :unsupported, detail: detail}] = problems_for(env, "DATABASE_PROVIDER")
      assert detail =~ "sqlite, turso, bunny, postgres"
      refute detail =~ "private-invalid-provider"
      assert env.settings.database == nil

      stale =
        Map.merge(@minimal, %{
          "DATABASE_PROVIDER" => "turso",
          "BUNNY_DATABASE_URL" => "https://db-id.lite.bunnydb.net"
        })

      env = prod(stale)
      assert [%{kind: :malformed, detail: detail}] = problems_for(env, "DATABASE_PROVIDER")
      assert detail =~ "conflicts with the BUNNY_DATABASE_*"
      assert env.settings.database == nil
    end

    test "an explicit remote provider needs a matching URL" do
      for {provider, wrong} <- [
            {"turso", "postgres://u:p@db/custyard"},
            {"postgres", "libsql://db-org.turso.io"}
          ] do
        env = prod(Map.put(@minimal, "DATABASE_PROVIDER", provider))
        assert [%{kind: :missing}] = problems_for(env, "DATABASE_URL"), provider
        assert env.settings.database == nil

        env =
          prod(Map.merge(@minimal, %{"DATABASE_PROVIDER" => provider, "DATABASE_URL" => wrong}))

        assert [%{kind: :malformed}] = problems_for(env, "DATABASE_URL"), provider
        assert env.settings.database == nil
      end

      turso = %{
        "DATABASE_PROVIDER" => "turso",
        "DATABASE_URL" => "libsql://db-org.turso.io",
        "TURSO_AUTH_TOKEN" => "tok"
      }

      assert prod(Map.merge(@minimal, turso)).settings.database ==
               {:turso, "libsql://db-org.turso.io", "tok"}

      postgres = %{
        "DATABASE_PROVIDER" => "postgres",
        "DATABASE_URL" => "postgresql://db/custyard"
      }

      assert prod(Map.merge(@minimal, postgres)).settings.database ==
               {:postgres, "postgresql://db/custyard"}
    end

    test "a token alone does not select SQLite, and sqlite refuses remote settings" do
      env = prod(Map.put(@minimal, "TURSO_AUTH_TOKEN", "orphan-token"))
      assert [%{kind: :missing, detail: detail}] = problems_for(env, "DATABASE_URL")
      assert detail =~ "TURSO_AUTH_TOKEN is set"
      assert env.settings.database == nil

      for {name, value} <- [
            {"TURSO_AUTH_TOKEN", "orphan-token"},
            {"DATABASE_URL", "libsql://db-org.turso.io"}
          ] do
        env = prod(Map.merge(@minimal, %{"DATABASE_PROVIDER" => "sqlite", name => value}))
        assert [%{kind: :malformed}] = problems_for(env, "DATABASE_PROVIDER"), name
        assert env.settings.database == nil
      end

      env =
        prod(
          Map.merge(@minimal, %{"DATABASE_PROVIDER" => "sqlite", "DATABASE_PATH" => "/d/c.db"})
        )

      assert env.verdict == :configured
      assert env.settings.database == {:sqlite, "/d/c.db"}
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

  describe "hosting" do
    test "defaults to nothing special, and to Fly on Fly" do
      env = prod(@minimal)
      assert env.settings.storage_provider == :local
      assert env.settings.proxy_provider == :none
      assert env.settings.trust_proxy_headers == false
      assert env.settings.data_volume_id == nil
      assert env.settings.bunny_origin_secret == nil

      fly = prod(Map.put(@minimal, "FLY_APP_NAME", "custyard-eu"))
      assert fly.settings.storage_provider == :fly
      assert fly.settings.proxy_provider == :fly
      assert fly.settings.trust_proxy_headers == true
    end

    test "Bunny Database selects neither the storage nor the proxy provider" do
      bunny = %{
        "BUNNY_DATABASE_URL" => "https://db-id.lite.bunnydb.net",
        "BUNNY_DATABASE_AUTH_TOKEN" => "tok"
      }

      env = prod(Map.merge(@minimal, bunny))
      assert env.settings.storage_provider == :local
      assert env.settings.proxy_provider == :none

      staging = prod(@minimal |> Map.merge(bunny) |> Map.put("FLY_APP_NAME", "custyard-staging"))
      assert staging.verdict == :configured
      assert staging.settings.turso_provider == :bunny
      assert staging.settings.storage_provider == :fly
      assert staging.settings.proxy_provider == :fly
      assert staging.settings.platform == :fly
    end

    test "explicit providers override Fly detection" do
      env =
        prod(
          Map.merge(@minimal, %{
            "FLY_APP_NAME" => "custyard-eu",
            "STORAGE_PROVIDER" => "local",
            "PROXY_PROVIDER" => "none"
          })
        )

      assert env.verdict == :configured
      assert env.settings.storage_provider == :local
      assert env.settings.proxy_provider == :none
      assert env.settings.trust_proxy_headers == false
    end

    test "an unknown provider is unsupported and its value is not echoed" do
      env = prod(Map.put(@minimal, "STORAGE_PROVIDER", "private-invalid-provider"))
      assert [%{kind: :unsupported, detail: detail}] = problems_for(env, "STORAGE_PROVIDER")
      assert detail == "must be one of local, fly, bunny"
      # Not a provider Custyard.Storage accepts, so release commands stop too.
      assert env.settings.storage_provider == :invalid

      env = prod(Map.put(@minimal, "PROXY_PROVIDER", "private-invalid-provider"))
      assert [%{kind: :unsupported, detail: detail}] = problems_for(env, "PROXY_PROVIDER")
      assert detail == "must be one of none, fly, bunny"
      assert env.settings.proxy_provider == :none
      refute inspect(env.problems) =~ "private-invalid-provider"

      fly =
        prod(Map.merge(@minimal, %{"FLY_APP_NAME" => "custyard-eu", "PROXY_PROVIDER" => "nope"}))

      # The platform default, so the doctor card naming the problem is reachable.
      assert fly.settings.proxy_provider == :fly
    end

    test "STORAGE_PROVIDER=bunny requires a well-formed DATA_VOLUME_ID" do
      env = prod(Map.put(@minimal, "STORAGE_PROVIDER", "bunny"))
      assert [%{kind: :missing, detail: detail}] = problems_for(env, "DATA_VOLUME_ID")
      assert detail =~ "bin/data-volume init"
      assert env.settings.storage_provider == :bunny
      assert env.settings.platform == :bunny

      env =
        prod(
          Map.merge(@minimal, %{"STORAGE_PROVIDER" => "bunny", "DATA_VOLUME_ID" => "../escape"})
        )

      assert [%{kind: :malformed, detail: detail}] = problems_for(env, "DATA_VOLUME_ID")
      refute detail =~ "escape"
      assert env.settings.data_volume_id == nil

      env =
        prod(
          Map.merge(@minimal, %{
            "STORAGE_PROVIDER" => "bunny",
            "DATA_VOLUME_ID" => "custyard-prod-files-v1"
          })
        )

      assert env.verdict == :configured
      assert env.settings.data_volume_id == "custyard-prod-files-v1"
    end

    test "PROXY_PROVIDER=bunny requires an origin secret of at least 32 bytes" do
      for value <- [nil, "", "short-private-value"] do
        vars = Map.put(@minimal, "PROXY_PROVIDER", "bunny")
        vars = if value, do: Map.put(vars, "BUNNY_ORIGIN_SECRET", value), else: vars
        env = prod(vars)

        assert [%{kind: kind}] = problems_for(env, "BUNNY_ORIGIN_SECRET")
        assert kind == if(value in [nil, ""], do: :missing, else: :malformed)
        refute inspect(env.problems) =~ "short-private-value"
        # nil: CustyardWeb.Proxy then refuses everything but the health probes.
        assert env.settings.proxy_provider == :bunny
        assert env.settings.bunny_origin_secret == nil
        assert env.settings.trust_proxy_headers == false
      end

      secret = String.duplicate("o", 32)

      env =
        prod(Map.merge(@minimal, %{"PROXY_PROVIDER" => "bunny", "BUNNY_ORIGIN_SECRET" => secret}))

      assert env.verdict == :configured
      assert env.settings.bunny_origin_secret == secret
      assert env.settings.trust_proxy_headers == false
      assert env.settings.platform == :bunny
    end

    test "the origin secret is ignored without the Bunny proxy" do
      env = prod(Map.put(@minimal, "BUNNY_ORIGIN_SECRET", "short"))
      assert env.verdict == :configured
      assert env.settings.bunny_origin_secret == nil
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
    test "SKIP_MIGRATIONS is a trimmed boolean, false by default" do
      assert prod(@minimal).settings.skip_migrations == false
      assert prod(Map.put(@minimal, "SKIP_MIGRATIONS", " true ")).settings.skip_migrations

      env = prod(Map.put(@minimal, "SKIP_MIGRATIONS", "yes"))
      assert [%{kind: :malformed}] = problems_for(env, "SKIP_MIGRATIONS")
      assert env.settings.skip_migrations == false
    end

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
    test "ACKNOWLEDGMENTS_PREFETCH must be 1..100" do
      assert prod(Map.put(@minimal, "ACKNOWLEDGMENTS_PREFETCH", "100")).problems == []
      env = prod(Map.put(@minimal, "ACKNOWLEDGMENTS_PREFETCH", "0"))
      assert [%{kind: :malformed}] = problems_for(env, "ACKNOWLEDGMENTS_PREFETCH")
    end
  end

  describe "IMAP_ENABLED" do
    test "anything but false is unsupported" do
      env = prod(Map.put(@minimal, "IMAP_ENABLED", "true"))
      assert [%{kind: :unsupported, detail: detail}] = problems_for(env, "IMAP_ENABLED")
      assert detail =~ "IMAP channel"
      # The page where a staff admin adds one; it moved off the organization page.
      assert detail =~ "/app/settings/email"
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

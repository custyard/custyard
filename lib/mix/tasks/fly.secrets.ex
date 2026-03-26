defmodule Mix.Tasks.Fly.Secrets do
  @shortdoc "Sync .env to Fly.io secrets and fly.toml [env]"
  @moduledoc """
  Makes .env the source of truth for Fly.io configuration.

  Sensitive variables go to `fly secrets import`.
  Non-sensitive variables update the `[env]` section in `fly.toml`.

  ## Usage

      # Preview what would be set (no changes made)
      mix fly.secrets

      # Apply changes: update fly.toml and set secrets
      mix fly.secrets --apply

      # Set secrets without redeploying
      mix fly.secrets --apply --stage

      # Target a specific app
      mix fly.secrets --apply --app custyard-staging

      # Use a different env file
      mix fly.secrets --env .env.production

  ## Variable classification

  **Secrets** (set via `fly secrets import`):
    SECRET_KEY_BASE, LIVE_VIEW_SIGNING_SALT, OPERATOR_PASSWORD,
    DATABASE_URL, TURSO_AUTH_TOKEN, LETTERMINT_API_TOKEN, WEBHOOK_TOKEN,
    MAILGUN_API_KEY, SENDGRID_API_KEY, POSTMARK_API_KEY, SMTP_PASSWORD,
    IMAP_PASSWORD

  **Config** (written to fly.toml [env]):
    PHX_HOST, PORT, MAIL_ADAPTER, LMTP_ENABLED, LMTP_PORT, LMTP_HOSTNAME,
    IMAP_ENABLED, IMAP_HOST, IMAP_PORT, IMAP_FOLDER, IMAP_POLL_INTERVAL,
    IMAP_SSL, IMAP_USERNAME, LETTERMINT_BASE_URL, SMTP_HOST, SMTP_PORT,
    SMTP_USERNAME, SMTP_SSL
  """

  use Mix.Task

  @secret_vars ~w(
    SECRET_KEY_BASE
    LIVE_VIEW_SIGNING_SALT
    OPERATOR_PASSWORD
    DATABASE_URL
    TURSO_AUTH_TOKEN
    LETTERMINT_API_TOKEN
    WEBHOOK_TOKEN
    MAILGUN_API_KEY
    SENDGRID_API_KEY
    POSTMARK_API_KEY
    SMTP_PASSWORD
    IMAP_PASSWORD
  )

  @config_vars ~w(
    PHX_HOST
    PORT
    MAIL_ADAPTER
    LMTP_ENABLED
    LMTP_PORT
    LMTP_HOSTNAME
    IMAP_ENABLED
    IMAP_HOST
    IMAP_PORT
    IMAP_FOLDER
    IMAP_POLL_INTERVAL
    IMAP_SSL
    IMAP_USERNAME
    LETTERMINT_BASE_URL
    SMTP_HOST
    SMTP_PORT
    SMTP_USERNAME
    SMTP_SSL
  )

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [apply: :boolean, stage: :boolean, app: :string, env: :string],
        aliases: [a: :app, e: :env]
      )

    env_file = opts[:env] || ".env"
    toml_file = "fly.toml"

    case File.read(env_file) do
      {:ok, content} ->
        all_vars = parse_env(content)
        secrets = filter_vars(all_vars, @secret_vars)
        config = filter_vars(all_vars, @config_vars)

        if opts[:apply] do
          apply_changes(secrets, config, toml_file, opts)
        else
          preview_changes(secrets, config, env_file, toml_file)
        end

      {:error, :enoent} ->
        Mix.shell().error("Error: #{env_file} not found")
        Mix.shell().error("Copy .env.sample to .env and fill in values")
        exit({:shutdown, 1})
    end
  end

  defp parse_env(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [var, value] ->
          var = String.trim(var)
          value = value |> String.trim() |> strip_quotes()
          if value != "", do: [{var, value}], else: []

        _ ->
          []
      end
    end)
  end

  defp filter_vars(all_vars, allowed) do
    Enum.filter(all_vars, fn {var, _} -> var in allowed end)
  end

  defp strip_quotes(value) do
    value
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp preview_changes(secrets, config, env_file, toml_file) do
    Mix.shell().info("Source: #{env_file}\n")

    if config != [] do
      Mix.shell().info("Config vars (will update #{toml_file} [env]):")

      Enum.each(config, fn {var, value} ->
        Mix.shell().info("  #{var} = \"#{value}\"")
      end)

      Mix.shell().info("")
    end

    if secrets != [] do
      Mix.shell().info("Secrets (will set via fly secrets import):")

      Enum.each(secrets, fn {var, value} ->
        Mix.shell().info("  #{var}=#{mask_value(value)}")
      end)

      Mix.shell().info("")
    end

    if secrets == [] and config == [] do
      Mix.shell().info("No recognized variables found in #{env_file}")
      Mix.shell().info("Secrets: #{Enum.join(@secret_vars, ", ")}")
      Mix.shell().info("Config: #{Enum.join(@config_vars, ", ")}")
    else
      Mix.shell().info("Run with --apply to make changes")
    end
  end

  defp apply_changes(secrets, config, toml_file, opts) do
    # Update fly.toml [env] section
    if config != [] do
      update_fly_toml(config, toml_file)
    end

    # Set secrets via fly secrets import
    if secrets != [] do
      set_fly_secrets(secrets, opts)
    end

    if secrets == [] and config == [] do
      Mix.shell().info("No changes to apply")
    end
  end

  defp update_fly_toml(config, toml_file) do
    case File.read(toml_file) do
      {:ok, content} ->
        new_content = update_env_section(content, config)
        File.write!(toml_file, new_content)
        Mix.shell().info("Updated #{toml_file} [env] with #{length(config)} variable(s)")

      {:error, :enoent} ->
        Mix.shell().error("Error: #{toml_file} not found")
        exit({:shutdown, 1})
    end
  end

  defp update_env_section(content, config) do
    # Build new [env] section
    env_lines =
      config
      |> Enum.sort_by(fn {var, _} -> var end)
      |> Enum.map(fn {var, value} -> "#{var} = \"#{value}\"" end)

    new_env = "[env]\n" <> Enum.join(env_lines, "\n")

    # Replace existing [env] section or insert after [build]
    cond do
      String.contains?(content, "[env]") ->
        # Replace existing [env] section (up to next section or EOF)
        Regex.replace(
          ~r/\[env\]\n(?:[A-Z_]+ = "[^"]*"\n?)*/,
          content,
          new_env <> "\n"
        )

      String.contains?(content, "[build]") ->
        # Insert after [build] section
        Regex.replace(
          ~r/(\[build\]\n[^\[]*)/,
          content,
          "\\1\n#{new_env}\n"
        )

      true ->
        # Append at end
        content <> "\n#{new_env}\n"
    end
  end

  defp set_fly_secrets(secrets, opts) do
    app_flag = if opts[:app], do: ["-a", opts[:app]], else: []
    stage_flag = if opts[:stage], do: ["--stage"], else: []

    Mix.shell().info("Setting #{length(secrets)} secret(s) via fly secrets import...")

    if opts[:stage] do
      Mix.shell().info("(Staging only - no redeploy)")
    end

    input = Enum.map_join(secrets, "\n", fn {var, value} -> "#{var}=#{value}" end)
    args = ["secrets", "import"] ++ app_flag ++ stage_flag

    case System.find_executable("fly") || System.find_executable("flyctl") do
      nil ->
        Mix.shell().error("Error: fly/flyctl not found in PATH")
        Mix.shell().error("Install from https://fly.io/docs/flyctl/install/")
        exit({:shutdown, 1})

      flyctl ->
        port =
          Port.open({:spawn_executable, flyctl}, [
            :binary,
            :exit_status,
            args: args
          ])

        Port.command(port, input)
        Port.command(port, :eof)

        wait_for_port(port)
    end
  end

  defp wait_for_port(port) do
    receive do
      {^port, {:data, data}} ->
        Mix.shell().info(String.trim(data))
        wait_for_port(port)

      {^port, {:exit_status, 0}} ->
        Mix.shell().info("Secrets set successfully")

      {^port, {:exit_status, code}} ->
        Mix.shell().error("fly secrets import failed with exit code #{code}")
        exit({:shutdown, code})
    after
      60_000 ->
        Mix.shell().error("Timeout waiting for fly secrets import")
        exit({:shutdown, 1})
    end
  end

  defp mask_value(value) when byte_size(value) > 8 do
    String.slice(value, 0, 4) <> "..." <> String.slice(value, -4, 4)
  end

  defp mask_value(_value), do: "****"
end

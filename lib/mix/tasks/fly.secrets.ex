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
    |> Enum.flat_map(&parse_env_line/1)
  end

  defp parse_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [var, value] ->
        var = String.trim(var)
        value = value |> String.trim() |> strip_quotes()
        build_var_entry(var, value)

      _ ->
        []
    end
  end

  defp build_var_entry(var, value) when value != "" do
    if valid_var_name?(var) do
      [{var, value}]
    else
      warn_invalid_var_name(var)
      []
    end
  end

  defp build_var_entry(_var, _value), do: []

  defp warn_invalid_var_name(var) when var != "" do
    Mix.shell().info("Skipping invalid variable name: #{var}")
  end

  defp warn_invalid_var_name(_var), do: :ok

  defp valid_var_name?(name) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name)
  end

  defp filter_vars(all_vars, allowed) do
    Enum.filter(all_vars, fn {var, _} -> var in allowed end)
  end

  defp strip_quotes(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
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

  # Regex for matching the [env] section in fly.toml up to the next section or EOF.
  #
  # Assumptions about fly.toml format (validated by Fly.io tooling):
  #   - Section headers are on their own line: [env]
  #   - Variables use format: KEY = "value" (spaces around =, double quotes)
  #   - Variable names: uppercase letters, digits, underscores (start with letter)
  #   - Next section header or EOF terminates the [env] block
  #   - Empty lines within [env] are allowed
  #
  # If your fly.toml uses a different format, this task will error.
  # Use preview mode first to verify changes before applying.
  @env_section_greedy_regex ~r/\[env\]\n(?:[^\[]*?)(?=\n\[|\z)/s

  defp update_env_section(content, config) do
    env_lines =
      config
      |> Enum.sort_by(fn {var, _} -> var end)
      |> Enum.map(fn {var, value} -> "#{var} = \"#{escape_toml_value(value)}\"" end)

    new_env = "[env]\n" <> Enum.join(env_lines, "\n")

    cond do
      String.contains?(content, "[env]") ->
        replace_existing_env_section(content, new_env, config)

      String.contains?(content, "[build]") ->
        insert_env_after_build(content, new_env)

      true ->
        content <> "\n#{new_env}\n"
    end
  end

  defp replace_existing_env_section(content, new_env, config) do
    case extract_and_validate_env_section(content) do
      {:ok, _existing_section} ->
        # Use function replacement to avoid backslash interpretation in new_env
        Regex.replace(@env_section_greedy_regex, content, fn _ -> new_env end, global: false)

      :invalid ->
        report_invalid_env_section(config)
    end
  end

  defp extract_and_validate_env_section(content) do
    case Regex.run(@env_section_greedy_regex, content) do
      [existing_section] when existing_section != "" ->
        if valid_env_section?(existing_section), do: {:ok, existing_section}, else: :invalid

      _ ->
        :invalid
    end
  end

  defp valid_env_section?(section) do
    # Check that everything after [env]\n is either:
    # - Empty lines
    # - KEY = "value" format lines
    # - Nothing (empty section)
    lines =
      section
      |> String.trim_leading("[env]\n")
      |> String.split("\n")

    Enum.all?(lines, fn line ->
      trimmed = String.trim(line)
      # Empty line, or properly formatted KEY = "value"
      trimmed == "" or Regex.match?(~r/^[A-Z][A-Z0-9_]* = "[^"]*"$/, trimmed)
    end)
  end

  defp report_invalid_env_section(config) do
    Mix.shell().error("""
    Error: Could not update [env] section in fly.toml.
    The existing [env] section has an unexpected format.

    Expected format:
      [env]
      KEY = "value"

    Found entries that don't match (lowercase names, missing quotes, etc.).
    Please fix fly.toml manually or remove the [env] section to let this task create it.

    Variables that would be set: #{Enum.map_join(config, ", ", fn {k, _} -> k end)}
    """)

    exit({:shutdown, 1})
  end

  defp insert_env_after_build(content, new_env) do
    # Insert after [build] section - matches [build] plus any non-section content
    # Use function replacement to avoid backslash interpretation in new_env
    result =
      Regex.replace(
        ~r/(\[build\]\n[^\[]*)/,
        content,
        fn _, build_section -> "#{build_section}\n#{new_env}\n" end,
        global: false
      )

    if result == content do
      # Fallback: [build] exists but regex didn't match its structure
      # This shouldn't happen in practice but append as fallback
      content <> "\n#{new_env}\n"
    else
      result
    end
  end

  defp escape_toml_value(value) do
    # Escape backslashes and double quotes for TOML string values
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp set_fly_secrets(secrets, opts) do
    validate_app_name(opts[:app])
    log_secrets_info(secrets, opts)

    args = build_fly_args(opts)
    secrets_input = Enum.map_join(secrets, "\n", fn {var, value} -> "#{var}=#{value}" end)

    run_fly_secrets_import(args, secrets_input)
  end

  defp validate_app_name(nil), do: :ok

  defp validate_app_name(app) do
    if valid_app_name?(app) do
      :ok
    else
      Mix.shell().error("Error: Invalid app name '#{app}'")
      Mix.shell().error("App names must contain only letters, numbers, and hyphens")
      exit({:shutdown, 1})
    end
  end

  defp log_secrets_info(secrets, opts) do
    Mix.shell().info("Setting #{length(secrets)} secret(s) via fly secrets import...")
    if opts[:stage], do: Mix.shell().info("(Staging only - no redeploy)")
  end

  defp build_fly_args(opts) do
    ["secrets", "import"]
    |> maybe_add_app_arg(opts[:app])
    |> maybe_add_stage_arg(opts[:stage])
  end

  defp maybe_add_app_arg(args, nil), do: args
  defp maybe_add_app_arg(args, app), do: args ++ ["-a", app]

  defp maybe_add_stage_arg(args, nil), do: args
  defp maybe_add_stage_arg(args, false), do: args
  defp maybe_add_stage_arg(args, true), do: args ++ ["--stage"]

  defp run_fly_secrets_import(args, secrets_input) do
    # Write secrets to a temp file and pipe to fly secrets import
    # (Elixir 1.19 removed the :stdin option from System.cmd)
    tmp_path = Path.join(System.tmp_dir!(), "fly_secrets_#{:rand.uniform(999_999)}")

    try do
      File.write!(tmp_path, secrets_input)
      args_str = Enum.map_join(args, " ", &shell_escape/1)

      case System.shell("fly #{args_str} < #{shell_escape(tmp_path)}", stderr_to_stdout: true) do
        {output, 0} ->
          log_output(output, :info)
          Mix.shell().info("Secrets set successfully")

        {output, code} ->
          log_output(output, :error)
          Mix.shell().error("fly secrets import failed with exit code #{code}")
          exit({:shutdown, code})
      end
    after
      File.rm(tmp_path)
    end
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp log_output("", _level), do: :ok
  defp log_output(output, :info), do: Mix.shell().info(String.trim(output))
  defp log_output(output, :error), do: Mix.shell().error(String.trim(output))

  defp valid_app_name?(name) do
    Regex.match?(~r/^[a-zA-Z0-9-]+$/, name)
  end

  defp mask_value(value) when byte_size(value) > 8 do
    String.slice(value, 0, 4) <> "..." <> String.slice(value, -4, 4)
  end

  defp mask_value(_value), do: "****"
end

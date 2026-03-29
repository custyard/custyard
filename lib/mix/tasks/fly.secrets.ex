defmodule Mix.Tasks.Fly.Secrets do
  @shortdoc "Sync .env and .env.secrets to Fly.io"
  @moduledoc """
  Syncs local env files to Fly.io configuration.

  `.env` values go to the `[env]` section in `fly.toml`.
  `.env.secrets` values go to `fly secrets import`.

  ## Usage

      # Preview what would be set (no changes made)
      mix fly.secrets

      # Apply changes: update fly.toml and set secrets
      mix fly.secrets --apply

      # Set secrets without redeploying
      mix fly.secrets --apply --stage

      # Target a specific app
      mix fly.secrets --apply --app custyard-staging

  ## File convention

  | File            | Destination              | Committed? |
  |-----------------|--------------------------|------------|
  | `.env`          | `fly.toml` `[env]`       | No         |
  | `.env.secrets`  | `fly secrets import`     | No         |

  Both files use standard dotenv format (`KEY=value`).
  """

  use Mix.Task

  @env_file ".env"
  @secrets_file ".env.secrets"
  @toml_file "fly.toml"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [apply: :boolean, stage: :boolean, app: :string],
        aliases: [a: :app]
      )

    config = read_env_file(@env_file)
    secrets = read_env_file(@secrets_file)

    if opts[:apply] do
      apply_changes(config, secrets, opts)
    else
      preview_changes(config, secrets)
    end
  end

  # -- .env parsing ----------------------------------------------------------

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_env(content)
      {:error, :enoent} -> :missing
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

        if value != "" and valid_var_name?(var) do
          [{var, value}]
        else
          if var != "" and not valid_var_name?(var) do
            Mix.shell().info("Skipping invalid variable name: #{var}")
          end

          []
        end

      _ ->
        []
    end
  end

  defp valid_var_name?(name) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name)
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

  # -- Preview ---------------------------------------------------------------

  defp preview_changes(config, secrets) do
    has_config = is_list(config) and config != []
    has_secrets = is_list(secrets) and secrets != []

    if has_config do
      Mix.shell().info("Config (#{@env_file} → #{@toml_file} [env]):")

      Enum.each(config, fn {var, value} ->
        Mix.shell().info("  #{var} = \"#{value}\"")
      end)

      Mix.shell().info("")
    end

    if has_secrets do
      Mix.shell().info("Secrets (#{@secrets_file} → fly secrets import):")

      Enum.each(secrets, fn {var, value} ->
        Mix.shell().info("  #{var}=#{mask_value(value)}")
      end)

      Mix.shell().info("")
    end

    if config == :missing, do: Mix.shell().info("No #{@env_file} found (skipping config)")
    if secrets == :missing, do: Mix.shell().info("No #{@secrets_file} found (skipping secrets)")

    if not has_config and not has_secrets do
      Mix.shell().info("Nothing to sync")
    else
      Mix.shell().info("")
      Mix.shell().info("Run with --apply to make changes")
    end
  end

  # -- Apply -----------------------------------------------------------------

  defp apply_changes(config, secrets, opts) do
    config_applied = apply_config(config)
    secrets_applied = apply_secrets(secrets, opts)

    if not config_applied and not secrets_applied do
      Mix.shell().info("Nothing to apply")
    end
  end

  defp apply_config(vars) when is_list(vars) and vars != [] do
    case File.read(@toml_file) do
      {:ok, content} ->
        new_content = update_env_section(content, vars)
        File.write!(@toml_file, new_content)
        Mix.shell().info("Updated #{@toml_file} [env] with #{length(vars)} variable(s)")
        true

      {:error, :enoent} ->
        Mix.shell().error("Error: #{@toml_file} not found")
        exit({:shutdown, 1})
    end
  end

  defp apply_config(_), do: false

  defp apply_secrets(vars, opts) when is_list(vars) and vars != [] do
    validate_app_name(opts[:app])
    Mix.shell().info("Setting #{length(vars)} secret(s) via fly secrets import...")
    if opts[:stage], do: Mix.shell().info("(Staging only - no redeploy)")

    args =
      ["secrets", "import"]
      |> maybe_add_flag("-a", opts[:app])
      |> maybe_add_flag("--stage", opts[:stage])

    secrets_input = Enum.map_join(vars, "\n", fn {var, value} -> "#{var}=#{value}" end)
    run_fly_secrets_import(args, secrets_input)
    true
  end

  defp apply_secrets(_, _), do: false

  # -- fly.toml [env] management ---------------------------------------------

  @env_section_greedy_regex ~r/\[env\]\n(?:[^\[]*?)(?=\n\[|\z)/s

  defp update_env_section(content, config) do
    env_lines =
      config
      |> Enum.sort_by(fn {var, _} -> var end)
      |> Enum.map(fn {var, value} -> "#{var} = \"#{escape_toml_value(value)}\"" end)

    new_env = "[env]\n" <> Enum.join(env_lines, "\n") <> "\n"

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
    lines =
      section
      |> String.trim_leading("[env]\n")
      |> String.split("\n")

    Enum.all?(lines, fn line ->
      trimmed = String.trim(line)
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

    Please fix fly.toml manually or remove the [env] section to let this task create it.

    Variables that would be set: #{Enum.map_join(config, ", ", fn {k, _} -> k end)}
    """)

    exit({:shutdown, 1})
  end

  defp insert_env_after_build(content, new_env) do
    result =
      Regex.replace(
        ~r/(\[build\]\n[^\[]*)/,
        content,
        fn _, build_section -> "#{build_section}\n#{new_env}\n" end,
        global: false
      )

    if result == content do
      content <> "\n#{new_env}\n"
    else
      result
    end
  end

  defp escape_toml_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # -- fly secrets import ----------------------------------------------------

  defp run_fly_secrets_import(args, secrets_input) do
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

  # -- Helpers ---------------------------------------------------------------

  defp validate_app_name(nil), do: :ok

  defp validate_app_name(app) do
    unless Regex.match?(~r/^[a-zA-Z0-9-]+$/, app) do
      Mix.shell().error("Error: Invalid app name '#{app}'")
      exit({:shutdown, 1})
    end
  end

  defp maybe_add_flag(args, _flag, nil), do: args
  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]
  defp maybe_add_flag(args, flag, value) when is_binary(value), do: args ++ [flag, value]

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp log_output("", _level), do: :ok
  defp log_output(output, :info), do: Mix.shell().info(String.trim(output))
  defp log_output(output, :error), do: Mix.shell().error(String.trim(output))

  defp mask_value(value) when byte_size(value) > 8 do
    String.slice(value, 0, 4) <> "..." <> String.slice(value, -4, 4)
  end

  defp mask_value(_value), do: "****"
end

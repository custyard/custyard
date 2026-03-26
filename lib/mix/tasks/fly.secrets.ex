defmodule Mix.Tasks.Fly.Secrets do
  @shortdoc "Set Fly.io secrets from .env file"
  @moduledoc """
  Sets Fly.io secrets by reading sensitive variables from .env file.

  ## Usage

      # Preview secrets that would be set (values masked)
      mix fly.secrets

      # Actually set the secrets
      mix fly.secrets --apply

      # Set secrets without redeploying
      mix fly.secrets --stage

      # Target a specific app
      mix fly.secrets --apply --app custyard-staging

  ## Secret variables

  Only these sensitive variables are extracted from .env:

    - SECRET_KEY_BASE
    - LIVE_VIEW_SIGNING_SALT
    - OPERATOR_PASSWORD
    - DATABASE_URL
    - TURSO_AUTH_TOKEN
    - LETTERMINT_API_TOKEN
    - WEBHOOK_TOKEN
    - MAILGUN_API_KEY
    - SENDGRID_API_KEY
    - POSTMARK_API_KEY
    - SMTP_PASSWORD
    - IMAP_PASSWORD

  Non-secrets (PHX_HOST, PORT, LMTP_ENABLED, etc.) belong in fly.toml [env].
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

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [apply: :boolean, stage: :boolean, app: :string, env: :string],
        aliases: [a: :app, e: :env]
      )

    env_file = opts[:env] || ".env"

    case File.read(env_file) do
      {:ok, content} ->
        secrets = extract_secrets(content)
        handle_secrets(secrets, opts, env_file)

      {:error, :enoent} ->
        Mix.shell().error("Error: #{env_file} not found")
        Mix.shell().error("Copy .env.sample to .env and fill in values")
        exit({:shutdown, 1})
    end
  end

  defp extract_secrets(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [var, value] ->
          var = String.trim(var)
          value = value |> String.trim() |> strip_quotes()

          if var in @secret_vars and value != "" do
            [{var, value}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp strip_quotes(value) do
    value
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp handle_secrets([], _opts, env_file) do
    Mix.shell().info("No secrets found in #{env_file}")
    Mix.shell().info("Expected variables: #{Enum.join(@secret_vars, ", ")}")
  end

  defp handle_secrets(secrets, opts, env_file) do
    if opts[:apply] do
      apply_secrets(secrets, opts)
    else
      preview_secrets(secrets, env_file, opts)
    end
  end

  defp preview_secrets(secrets, env_file, _opts) do
    Mix.shell().info("Preview: #{length(secrets)} secret(s) from #{env_file}:\n")

    Enum.each(secrets, fn {var, value} ->
      masked = mask_value(value)
      Mix.shell().info("  #{var}=#{masked}")
    end)

    Mix.shell().info("")
    Mix.shell().info("Run with --apply to set secrets, or --stage to set without redeploying")
  end

  defp apply_secrets(secrets, opts) do
    app_flag = if opts[:app], do: ["-a", opts[:app]], else: []
    stage_flag = if opts[:stage], do: ["--stage"], else: []

    Mix.shell().info("Setting #{length(secrets)} secret(s)...")

    if opts[:stage] do
      Mix.shell().info("(Staging only - no redeploy)")
    end

    # Build input for fly secrets import
    input = Enum.map_join(secrets, "\n", fn {var, value} -> "#{var}=#{value}" end)

    args = ["secrets", "import"] ++ app_flag ++ stage_flag

    port =
      Port.open({:spawn_executable, find_flyctl()}, [
        :binary,
        :exit_status,
        args: args
      ])

    Port.command(port, input)
    Port.command(port, :eof)

    receive do
      {^port, {:data, data}} ->
        Mix.shell().info(data)

      {^port, {:exit_status, 0}} ->
        Mix.shell().info("Done.")

      {^port, {:exit_status, code}} ->
        Mix.shell().error("fly secrets import failed with exit code #{code}")
        exit({:shutdown, code})
    after
      30_000 ->
        Mix.shell().error("Timeout waiting for fly secrets import")
        exit({:shutdown, 1})
    end
  end

  defp find_flyctl do
    case System.find_executable("fly") || System.find_executable("flyctl") do
      nil ->
        Mix.shell().error("Error: fly/flyctl not found in PATH")
        Mix.shell().error("Install from https://fly.io/docs/flyctl/install/")
        exit({:shutdown, 1})

      path ->
        path
    end
  end

  defp mask_value(value) when byte_size(value) > 8 do
    String.slice(value, 0, 4) <> "..." <> String.slice(value, -4, 4)
  end

  defp mask_value(_value), do: "****"
end

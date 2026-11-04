defmodule Custyard.Boot.Report do
  @moduledoc """
  Renders a `Custyard.Boot.Env` for the boot log and the doctor card.

  Names only, never values: the text goes through the privacy logger and the
  card is public while the instance is unconfigured.
  """

  alias Custyard.Boot.Env

  @placeholder_host "‹custyard.example.com›"
  @placeholder_email "‹you@example.com›"

  @credential_placeholders %{
    lettermint: [{"LETTERMINT_PROJECT_TOKEN", "‹project token›"}],
    mailgun: [{"MAILGUN_API_KEY", "‹api key›"}, {"MAILGUN_DOMAIN", "‹mail.example.com›"}],
    sendgrid: [{"SENDGRID_API_KEY", "‹api key›"}],
    postmark: [{"POSTMARK_API_KEY", "‹server token›"}],
    smtp: [{"SMTP_HOST", "‹smtp.example.com›"}],
    local: []
  }

  @doc """
  Plain-text report for the boot log.

  Options: `build: %{version:, git_sha:, built_at:}` and `booted_at:` are
  printed when given.
  """
  @spec to_text(Env.t(), keyword) :: String.t()
  def to_text(%Env{} = env, opts \\ []) do
    [
      headline(env),
      "",
      findings(env),
      "",
      "Environment",
      environment_lines(env, opts)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Copy-paste environment block for the doctor card: one line per required
  variable that is still missing, with a freshly generated SECRET_KEY_BASE and
  CREDENTIAL_ENCRYPTION_KEY.
  """
  @spec paste_block(Env.t()) :: String.t()
  def paste_block(%Env{settings: settings}) do
    [
      if(is_nil(settings.secret_key_base), do: "SECRET_KEY_BASE=#{generate_secret()}"),
      if(is_nil(settings.credential_keys.current),
        do: "CREDENTIAL_ENCRYPTION_KEY=#{generate_credential_key()}"
      ),
      if(is_nil(settings.host), do: "PHX_HOST=#{@placeholder_host}"),
      if(is_nil(settings.operator_email), do: "OPERATOR_EMAIL=#{@placeholder_email}"),
      mail_lines(settings.mail)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp headline(%Env{verdict: :unconfigured}) do
    [
      "Custyard is not configured yet",
      "This instance started without the settings it needs. Nothing has been written. " <>
        "Set these and restart."
    ]
  end

  defp headline(%Env{verdict: :configured}) do
    ["Custyard configuration is complete"]
  end

  defp findings(%Env{problems: [], warnings: []}), do: ["  (no problems or warnings)"]

  defp findings(%Env{problems: problems, warnings: warnings}) do
    width =
      (problems ++ warnings)
      |> Enum.map(&String.length(&1.variable || ""))
      |> Enum.max(fn -> 0 end)

    Enum.map(problems, fn p ->
      "  ✗  #{String.pad_trailing(p.variable, width)}  #{p.kind}  #{p.detail}"
    end) ++
      Enum.map(warnings, fn w ->
        "  ⚠  #{String.pad_trailing(w.variable || "", width)}  #{w.detail}"
      end)
  end

  defp environment_lines(env, opts) do
    [
      build_line(Keyword.get(opts, :build)),
      booted_line(Keyword.get(opts, :booted_at)),
      row("Variables", variables_summary(env)),
      row("Present", names_or(env.present, "none of the Custyard settings")),
      row("Near misses", near_misses(env.near_misses)),
      row("Database", database(env.settings)),
      row("Platform", to_string(env.settings[:platform] || :unknown))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_line(nil), do: nil

  defp build_line(%{} = build) do
    parts =
      [
        build[:version] && "custyard #{build[:version]}",
        build[:git_sha] && "git #{build[:git_sha]}",
        build[:built_at] && "built #{format_time(build[:built_at])}"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: row("Image", Enum.join(parts, " · "))
  end

  defp booted_line(nil), do: nil
  defp booted_line(time), do: row("Booted", format_time(time))

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_time(other), do: to_string(other)

  defp variables_summary(%Env{variable_count: total, present: present}) do
    "#{total} visible · #{length(present)} of them Custyard settings"
  end

  defp names_or([], fallback), do: fallback
  defp names_or(names, _fallback), do: Enum.join(names, "  ")

  defp near_misses([]), do: "none"

  defp near_misses(misses) do
    Enum.map_join(misses, "  ", fn %{found: found, expected: expected} ->
      "#{found} (did you mean #{expected})"
    end)
  end

  defp database(settings) do
    reason = settings[:database_reason] || "undecided"

    kind =
      case settings[:database] do
        {:sqlite, path} -> "SQLite file #{path}"
        {:turso, _url, _token} -> "remote libSQL"
        {:postgres, _url} -> "PostgreSQL"
        nil -> "none"
      end

    "#{kind} · #{reason}"
  end

  defp row(label, value), do: "  #{String.pad_trailing(label, 12)} #{value}"

  defp mail_lines(nil) do
    ["MAIL_ADAPTER=lettermint" | credential_lines(:lettermint, nil)]
  end

  defp mail_lines(%{adapter: adapter, config: config}) do
    credential_lines(adapter, config)
  end

  defp credential_lines(adapter, config) do
    @credential_placeholders
    |> Map.fetch!(adapter)
    |> Enum.reject(fn {name, _} -> config_has?(config, name) end)
    |> Enum.map(fn {name, placeholder} -> "#{name}=#{placeholder}" end)
  end

  defp config_has?(nil, _name), do: false

  defp config_has?(config, name) do
    key =
      case name do
        "LETTERMINT_PROJECT_TOKEN" -> :api_token
        "MAILGUN_API_KEY" -> :api_key
        "MAILGUN_DOMAIN" -> :domain
        "SENDGRID_API_KEY" -> :api_key
        "POSTMARK_API_KEY" -> :api_key
        "SMTP_HOST" -> :relay
      end

    is_binary(Keyword.get(config, key))
  end

  defp generate_secret, do: Base.encode64(:crypto.strong_rand_bytes(64))
  defp generate_credential_key, do: Base.encode64(:crypto.strong_rand_bytes(32))
end

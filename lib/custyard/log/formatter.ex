defmodule Custyard.Log.Formatter do
  @moduledoc "One bounded JSON record per line, safe even without the primary filter."

  def check_config(config) when is_map(config), do: :ok
  def check_config(_config), do: {:error, :invalid_config}

  def format(event, _config) do
    safe = Custyard.Log.filter(event, nil)
    {:string, name} = safe.msg
    fields = Custyard.Log.sanitize_metadata(safe.meta)

    timestamp =
      case DateTime.from_unix(safe.meta[:time] || System.system_time(:microsecond), :microsecond) do
        {:ok, value} -> DateTime.to_iso8601(value)
        _ -> DateTime.utc_now() |> DateTime.to_iso8601()
      end

    record =
      Map.merge(fields, %{
        timestamp: timestamp,
        level: to_string(safe.level),
        event: name,
        service: "custyard",
        schema_version: 1
      })

    record =
      case safe.meta[:mfa] do
        {module, function, arity} ->
          Map.put(record, :code_location, fields[:origin] || "#{module}.#{function}/#{arity}")

        _ ->
          record
      end

    [Jason.encode!(record), "\n"]
  rescue
    _ ->
      "{\"event\":\"log_event_rejected\",\"level\":\"error\",\"service\":\"custyard\",\"schema_version\":1}\n"
  end
end

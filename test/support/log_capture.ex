defmodule Custyard.LogCapture do
  @moduledoc false
  alias Custyard.Log.Formatter

  # Sequential integration tests use the same formatter and post-filter event
  # as production, rather than the text formatter used by CaptureLog.
  def with_json(fun) do
    handler = :custyard_json_test_capture
    :ok = :logger.add_handler(handler, __MODULE__, %{level: :debug, config: %{owner: self()}})

    try do
      {result, _text} = ExUnit.CaptureLog.with_log(fun)
      Logger.flush()
      {result, collect([])}
    after
      :logger.remove_handler(handler)
    end
  end

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  def log(event, %{config: %{owner: owner}}) do
    json = Formatter.format(event, %{}) |> IO.iodata_to_binary()
    send(owner, {:custyard_json_record, Jason.decode!(json)})
  end

  defp collect(acc) do
    receive do
      {:custyard_json_record, record} -> collect([record | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

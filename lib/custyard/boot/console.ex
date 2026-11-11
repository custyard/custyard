defmodule Custyard.Boot.Console do
  @moduledoc """
  The one place the boot writes plain text to stdout.

  The structured logger carries no free text, so the boot report
  (`Custyard.Boot.Report.to_text/2`: variable names, verdicts and counts,
  never values) is printed here as well, so that `docker logs` or
  `fly logs` on a fresh install show what to set. The source-level logging
  gate lists this module as a reviewed output path; keep it to that report.
  """

  @spec puts(iodata) :: :ok
  def puts(text), do: IO.puts(text)
end

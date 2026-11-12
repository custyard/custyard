defmodule Custyard.Attachments.Scanner do
  @moduledoc """
  Malware scanning boundary. It scans bytes the caller already holds:
  `Custyard.Attachments` passes a fresh download, or content read back from
  the database for a rescan. A missing scanner or any unexpected result keeps
  the attachment quarantined. No engine diagnostics or file contents are logged.
  """

  @max_bytes 100 * 1_048_576
  @callback scan(binary(), keyword()) :: :clean | :infected | {:error, atom()}

  @doc "The most content a scan accepts, in bytes. Callers do not load more than this."
  def max_bytes, do: @max_bytes

  @doc "Whether a scanner is configured. Without one `scan/2` gives no verdict, only `:pending`."
  def configured?, do: not is_nil(Application.get_env(:custyard, :attachment_scanner))

  @doc """
  The verdict for `bytes`: `:clean` or `:infected` from the configured
  scanner, `:pending` when none is configured, `:error` for anything else.
  """
  def scan(bytes, opts \\ []) do
    case Keyword.get(opts, :scanner, Application.get_env(:custyard, :attachment_scanner)) do
      nil -> :pending
      scanner -> verdict(scanner.scan(bytes, scanner_options(opts)))
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp scanner_options(opts),
    do:
      Keyword.get(
        opts,
        :scanner_options,
        Application.get_env(:custyard, :attachment_scanner_options, [])
      )

  defp verdict(:clean), do: :clean
  defp verdict(:infected), do: :infected
  defp verdict(_), do: :error
end

defmodule Custyard.Attachments.Scanner do
  @moduledoc """
  Malware scanning boundary. A missing scanner or any unexpected result keeps
  the attachment quarantined. No engine diagnostics or file contents are logged.
  """

  @max_bytes 100 * 1_048_576
  @callback scan(binary(), keyword()) :: :clean | :infected | {:error, atom()}

  def max_bytes, do: @max_bytes

  def scan_file(path, expected_sha, opts \\ []) do
    with {:ok, %{size: size, type: :regular}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_bytes,
         true <- digest(bytes) == expected_sha do
      scan(bytes, opts)
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

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
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

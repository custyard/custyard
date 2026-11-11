defmodule Custyard.Attachments.TestScanner do
  @moduledoc false
  @behaviour Custyard.Attachments.Scanner

  @impl true
  def scan("CUSTYARD_TEST_INFECTED" <> _, _opts), do: :infected
  def scan("CUSTYARD_TEST_SCAN_ERROR" <> _, _opts), do: {:error, :unavailable}
  def scan(_bytes, _opts), do: :clean
end

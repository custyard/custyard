defmodule Custyard.UploadPath do
  @moduledoc """
  Shared validation for operator-supplied upload paths (logo URLs).

  Only same-origin `/uploads/` paths are accepted - external URLs are
  rejected to prevent tracking/SSRF, and path traversal (literal and
  URL-encoded) and null bytes are rejected. Used by organization branding
  (`Custyard.Organization`) and instance branding (`Custyard.Settings`)
  so the two can never diverge.
  """

  @doc """
  Validate an upload path.

  Returns `:ok` or `{:error, message}` where the message is suitable for
  use as a changeset error.
  """
  def validate(path) when is_binary(path) do
    downcased = String.downcase(path)

    cond do
      # Only allow /uploads/ paths - no external URLs to prevent tracking/SSRF
      not String.starts_with?(path, "/uploads/") ->
        {:error, "must start with /uploads/"}

      # Reject path traversal sequences
      String.contains?(path, "..") ->
        {:error, "must not contain path traversal sequences"}

      # Reject URL-encoded path traversal (%2e = .)
      String.contains?(downcased, "%2e") ->
        {:error, "must not contain encoded path traversal"}

      # Reject null bytes
      String.contains?(path, "\0") or String.contains?(downcased, "%00") ->
        {:error, "must not contain null bytes"}

      true ->
        :ok
    end
  end

  def validate(_path), do: {:error, "must be a string"}

  @doc """
  Returns true if `path` is a valid upload path.
  """
  def valid?(path), do: validate(path) == :ok
end

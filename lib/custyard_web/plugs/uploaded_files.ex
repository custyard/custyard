defmodule CustyardWeb.Plugs.UploadedFiles do
  @moduledoc """
  Serves uploaded files from the configured :upload_dir with security controls.

  In dev, this is typically priv/static/uploads (already served by Plug.Static).
  In production, this is a persistent directory like /data/uploads that survives
  deployments.

  ## Security Features

  - **MIME type allowlist**: Only serves image files to prevent serving arbitrary content
  - **Content-Disposition**: Forces download for non-image types (prevents XSS from HTML)
  - **Path traversal protection**: Rejects paths with `..` or encoded traversal sequences
  - **Extension validation**: Validates file extension matches allowed types

  Note: Files are not authenticated because logo URLs need to be publicly accessible
  in the portal. Security relies on UUID filenames being unguessable.
  """

  @behaviour Plug
  import Plug.Conn

  # Only allow these file types to be served
  # This prevents serving uploaded HTML/JS that could enable XSS
  @allowed_extensions ~w(.png .jpg .jpeg .gif .webp .svg)

  # MIME types that can be rendered inline (safe image types)
  # Note: SVG can contain JavaScript but is allowed for logo display.
  # CSP headers restrict script execution in served files.
  @safe_inline_types ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/uploads/" <> subpath} = conn, _opts) do
    upload_dir = Application.get_env(:custyard, :upload_dir)

    cond do
      # No upload directory configured
      is_nil(upload_dir) ->
        conn

      # Path traversal attempt - reject
      path_traversal?(subpath) ->
        send_resp(conn, 400, "Invalid path") |> halt()

      # Invalid file extension - reject
      not allowed_extension?(subpath) ->
        send_resp(conn, 403, "File type not allowed") |> halt()

      # Valid request - serve with security headers
      true ->
        serve_file(conn, upload_dir, subpath)
    end
  end

  def call(conn, _opts), do: conn

  # Check for path traversal attempts or absolute paths
  defp path_traversal?(path) do
    # Reject absolute paths (Path.join ignores base when path is absolute)
    String.starts_with?(path, "/") or
      String.contains?(path, "..") or
      String.contains?(path, "%2e%2e") or
      String.contains?(path, "%2E%2E")
  end

  # Validate file extension against allowlist
  defp allowed_extension?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @allowed_extensions
  end

  # Serve the file with appropriate security headers
  defp serve_file(conn, upload_dir, subpath) do
    file_path = Path.join(upload_dir, subpath)
    # Expand to absolute path and verify it's still under upload_dir
    # This is a belt-and-suspenders check after path_traversal? validation
    expanded_path = Path.expand(file_path)
    expanded_base = Path.expand(upload_dir)

    cond do
      # Path escaped upload_dir (shouldn't happen after path_traversal? check)
      not String.starts_with?(expanded_path, expanded_base <> "/") ->
        send_resp(conn, 400, "Invalid path") |> halt()

      not File.exists?(file_path) ->
        # File not found - let Plug.Static or next plug handle 404
        conn

      true ->
        content_type = MIME.from_path(subpath)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("x-content-type-options", "nosniff")
        # Prevent script execution in SVG files
        |> put_resp_header("content-security-policy", "script-src 'none'")
        |> maybe_add_disposition_header(content_type)
        |> send_file(200, file_path)
        |> halt()
    end
  end

  # Force download for non-image types to prevent XSS
  defp maybe_add_disposition_header(conn, content_type) do
    if content_type in @safe_inline_types do
      conn
    else
      put_resp_header(conn, "content-disposition", "attachment")
    end
  end
end

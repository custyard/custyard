defmodule CustyardWeb.Plugs.UploadedFiles do
  @moduledoc """
  Serves tenant logos at `/uploads/logos/<key>` from the application database.

  A logo is a `Custyard.Files` file of kind `:logo` (see
  `CustyardWeb.Uploads`). Nothing is read from disk. A `/uploads/` path is
  refused with 400 for traversal and 403 for an extension outside the
  allowlist. Any other one that is not a stored logo goes on to the router,
  which answers 404; so does a logo whose content fails its integrity check.

  The lookup uses the Repo and this plug runs in the endpoint ahead of the
  router, so it must stay behind `CustyardWeb.Plugs.BootGate`: while the app
  is unconfigured, starting or without its database the Repo is not running,
  and the gate answers those requests before they get here.

  ## Security

  - **No session**: a logo has to load in the portal and in email, so the
    request is not authenticated and the lookup is not scoped to a tenant.
    The UUID in the key is what keeps an unpublished logo private.
  - **Extension allowlist**: only image extensions are answered, with the
    content type taken from the extension and `nosniff`, so stored bytes are
    never served as HTML or script.
  - **SVG**: an SVG can carry script. Every response has
    `content-security-policy: script-src 'none'`, which stops it running when
    the file is opened directly.
  - **Content-Disposition**: a type that is not a safe inline image is sent
    as a download.
  - **Traversal**: paths with `..`, encoded or not, are refused before the
    lookup.

  ## Caching

  A key is never reused for other content, so a logo is served as immutable
  for a year, with a strong `etag` made from its SHA-256. A request whose
  `if-none-match` names that tag gets 304 and the content is not read.
  """

  @behaviour Plug
  import Plug.Conn

  alias Custyard.Files
  alias Custyard.Files.StoredFile
  alias CustyardWeb.Uploads
  alias Plug.Conn.Utils

  # Only these file types are answered. Uploaded HTML or JavaScript served
  # from this origin would be XSS.
  @allowed_extensions ~w(.png .jpg .jpeg .gif .webp .svg)

  # MIME types that can be rendered inline (safe image types).
  # SVG can contain JavaScript but is allowed for logo display; the CSP
  # header stops script execution in the served file.
  @safe_inline_types ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  @cache_control "public, max-age=31536000, immutable"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/uploads/" <> subpath} = conn, _opts) do
    cond do
      # Path traversal attempt - reject
      path_traversal?(subpath) ->
        send_resp(conn, 400, "Invalid path") |> halt()

      # Invalid file extension - reject
      not allowed_extension?(subpath) ->
        send_resp(conn, 403, "File type not allowed") |> halt()

      true ->
        serve(conn, subpath)
    end
  end

  def call(conn, _opts), do: conn

  # Traversal sequences and a second leading slash never name an upload.
  defp path_traversal?(path) do
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

  # Conditional requests are defined for GET and HEAD, so only those are
  # answered; anything else goes on to the router like a missing file.
  defp serve(%Plug.Conn{method: method} = conn, "logos/" <> filename)
       when method in ["GET", "HEAD"] do
    with {:ok, key} <- Uploads.logo_key(filename),
         %StoredFile{} = file <- Files.get_public(:logo, key) do
      send_logo(conn, file, key)
    else
      :error -> conn
      nil -> conn
    end
  end

  defp serve(conn, _subpath), do: conn

  defp send_logo(conn, %StoredFile{} = file, key) do
    etag = ~s("#{file.sha256}")

    cached =
      conn
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("etag", etag)

    if etag_matches?(conn, etag) do
      cached |> send_resp(304, "") |> halt()
    else
      send_content(conn, cached, file, key)
    end
  end

  # `conn` is the request as it arrived: that is what goes on to the router
  # when the content cannot be trusted.
  #
  # Sobelow flags the body as user-controlled, and it is: these are uploaded
  # bytes. They cannot run as a page. The content type is the image type of
  # an extension in @allowed_extensions, sent with nosniff, and the CSP
  # header stops script inside an SVG.
  # sobelow_skip ["XSS.SendResp"]
  defp send_content(conn, cached, file, key) do
    case Files.read(file) do
      {:ok, content} ->
        content_type = MIME.from_path(key)

        cached
        |> put_resp_content_type(content_type)
        |> put_resp_header("x-content-type-options", "nosniff")
        # Prevent script execution in SVG files
        |> put_resp_header("content-security-policy", "script-src 'none'")
        |> maybe_add_disposition_header(content_type)
        |> send_resp(200, content)
        |> halt()

      {:error, :corrupt} ->
        conn
    end
  end

  # If-None-Match compares weakly: a proxy that compressed the response may
  # have turned the tag into `W/"..."`.
  defp etag_matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&Utils.list/1)
    |> Enum.any?(&(&1 == "*" or String.replace_prefix(&1, "W/", "") == etag))
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

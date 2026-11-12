defmodule CustyardWeb.Plugs.UploadedFilesTest do
  # Custyard.Boot.State lives in :persistent_term, which is global.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Ecto.Query
  import Plug.Test, only: [conn: 2]

  alias Custyard.Boot.{Env, State}
  alias Custyard.Files
  alias Custyard.Files.Chunk
  alias Custyard.Repo
  alias CustyardWeb.Plugs.UploadedFiles

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "logo bytes">>
  @svg ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|

  setup do
    %{tenant: insert_tenant()}
  end

  # Stores a logo of the tenant under `name` (default: a new UUID with `ext`)
  # and returns its public path and stored file.
  defp store_logo(tenant, ext, bytes \\ @png, name \\ nil) do
    key = name || Ecto.UUID.generate() <> ext
    {:ok, stored} = Files.put(tenant.id, :logo, key, bytes)
    %{path: "/uploads/logos/" <> key, key: key, stored: stored}
  end

  defp call(path), do: UploadedFiles.call(conn(:get, path), [])

  defp drop_chunks(stored), do: Repo.delete_all(from c in Chunk, where: c.file_id == ^stored.id)

  describe "init/1" do
    test "returns options unchanged" do
      opts = [some: :option]
      assert UploadedFiles.init(opts) == opts
    end
  end

  describe "call/2 path matching" do
    test "passes through non-upload paths" do
      result = call("/other/path")

      refute result.halted
      refute result.status
    end

    test "serves a stored logo with its exact bytes", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      result = call(logo.path)

      assert result.halted
      assert result.status == 200
      assert result.resp_body == @png
    end

    test "serves content that spans several chunks", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(2 * Files.chunk_bytes() + 17)
      logo = store_logo(tenant, ".png", bytes)

      result = call(logo.path)

      assert result.status == 200
      assert result.resp_body == bytes
    end

    test "passes through an unknown key" do
      request = conn(:get, "/uploads/logos/#{Ecto.UUID.generate()}.png")

      # Unchanged, so the router answers 404.
      assert UploadedFiles.call(request, []) == request
    end

    test "passes through /uploads/ paths outside logos/", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      for path <- ["/uploads/#{logo.key}", "/uploads/other/#{logo.key}"] do
        result = call(path)

        refute result.halted
        refute result.status
      end
    end

    test "passes through a subdirectory below logos/", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      result = call("/uploads/logos/subdir/#{logo.key}")

      refute result.halted
      refute result.status
    end

    test "passes through a name that is not a valid key" do
      result = call("/uploads/logos/my image.png")

      refute result.halted
      refute result.status
    end

    test "never serves an attachment stored under the same key", %{tenant: tenant} do
      key = Ecto.UUID.generate() <> ".png"
      {:ok, _} = Files.put(tenant.id, :attachment, key, @png)

      refute call("/uploads/logos/#{key}").halted
    end

    test "answers HEAD like GET", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      result = UploadedFiles.call(conn(:head, logo.path), [])

      assert result.halted
      assert result.status == 200
      assert get_resp_header(result, "etag") == [~s("#{logo.stored.sha256}")]
    end

    test "passes other methods through", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      for method <- [:post, :put, :delete] do
        result = UploadedFiles.call(conn(method, logo.path), [])

        refute result.halted
        refute result.status
      end
    end
  end

  describe "path traversal protection" do
    test "rejects paths with .." do
      result = call("/uploads/../../../etc/passwd")

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects paths with .. in subdirectory" do
      result = call("/uploads/subdir/../secret.png")

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects .. below logos/" do
      result = call("/uploads/logos/../logos/secret.png")

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects URL-encoded traversal (lowercase)" do
      # %2e%2e is URL-encoded ".."
      result = call("/uploads/%2e%2e/secret.png")

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects URL-encoded traversal (uppercase)" do
      # %2E%2E is URL-encoded ".."
      result = call("/uploads/%2E%2E/secret.png")

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects mixed encoded traversal" do
      # Mix of encoded and plain
      result = call("/uploads/foo/%2e%2e/bar/%2E%2E/secret.png")

      assert result.halted
      assert result.status == 400
    end

    test "rejects a second leading slash" do
      result = call("/uploads//etc/logo.png")

      assert result.halted
      assert result.status == 400
    end

    test "allows keys with single dots", %{tenant: tenant} do
      logo = store_logo(tenant, ".png", @png, "file.name.png")

      assert call(logo.path).status == 200
    end
  end

  describe "extension allowlist validation" do
    test "serves every allowed image extension", %{tenant: tenant} do
      for ext <- ~w(.png .jpg .jpeg .gif .webp .svg) do
        logo = store_logo(tenant, ext)

        assert call(logo.path).status == 200, "expected #{ext} to be served"
      end
    end

    test "finds the lowercased key for an uppercase extension", %{tenant: tenant} do
      logo = store_logo(tenant, ".png", @png, "IMAGE.png")

      result = call("/uploads/logos/IMAGE.PNG")

      assert result.status == 200
      assert result.resp_body == @png
      assert get_resp_header(result, "content-type") == ["image/png; charset=utf-8"]
      assert logo.key == "IMAGE.png"
    end

    test "finds the lowercased key for a mixed case extension", %{tenant: tenant} do
      store_logo(tenant, ".jpeg", @png, "image.jpeg")

      assert call("/uploads/logos/image.JpEg").status == 200
    end

    test "rejects .html files" do
      result = call("/uploads/malicious.html")

      assert result.halted
      assert result.status == 403
      assert result.resp_body == "File type not allowed"
    end

    test "rejects .js files" do
      result = call("/uploads/script.js")

      assert result.halted
      assert result.status == 403
      assert result.resp_body == "File type not allowed"
    end

    test "rejects .exe files" do
      result = call("/uploads/virus.exe")

      assert result.halted
      assert result.status == 403
    end

    test "rejects .php files" do
      result = call("/uploads/shell.php")

      assert result.halted
      assert result.status == 403
    end

    test "rejects files without extension" do
      result = call("/uploads/noextension")

      assert result.halted
      assert result.status == 403
    end

    test "rejects double extension attacks" do
      # Attacker might try to sneak past with image.png.html
      result = call("/uploads/image.png.html")

      assert result.halted
      assert result.status == 403
    end

    test "rejects a stored logo key with a disallowed extension", %{tenant: tenant} do
      logo = store_logo(tenant, ".html", "<script>alert(1)</script>")

      result = call(logo.path)

      assert result.halted
      assert result.status == 403
      assert result.resp_body == "File type not allowed"
    end
  end

  describe "MIME type handling" do
    test "sets the content type from the extension", %{tenant: tenant} do
      for {ext, type} <- [
            {".png", "image/png"},
            {".jpg", "image/jpeg"},
            {".jpeg", "image/jpeg"},
            {".svg", "image/svg+xml"},
            {".gif", "image/gif"},
            {".webp", "image/webp"}
          ] do
        logo = store_logo(tenant, ext)

        assert get_resp_header(call(logo.path), "content-type") == ["#{type}; charset=utf-8"]
      end
    end
  end

  describe "Content-Disposition header" do
    test "is not added for the image types served inline", %{tenant: tenant} do
      for ext <- ~w(.png .jpg .gif .webp .svg) do
        logo = store_logo(tenant, ext)

        assert get_resp_header(call(logo.path), "content-disposition") == []
      end
    end
  end

  describe "CSP headers for SVG files" do
    test "adds script-src none CSP header for SVG", %{tenant: tenant} do
      logo = store_logo(tenant, ".svg", @svg)

      result = call(logo.path)

      assert result.resp_body == @svg
      assert get_resp_header(result, "content-type") == ["image/svg+xml; charset=utf-8"]
      assert get_resp_header(result, "content-security-policy") == ["script-src 'none'"]
    end

    test "adds CSP header for all served files", %{tenant: tenant} do
      # CSP is added to all files for defense in depth
      logo = store_logo(tenant, ".png")

      assert get_resp_header(call(logo.path), "content-security-policy") == ["script-src 'none'"]
    end
  end

  describe "X-Content-Type-Options header" do
    test "adds nosniff header", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      assert get_resp_header(call(logo.path), "x-content-type-options") == ["nosniff"]
    end

    test "prevents MIME type sniffing for SVG", %{tenant: tenant} do
      logo = store_logo(tenant, ".svg", @svg)

      assert get_resp_header(call(logo.path), "x-content-type-options") == ["nosniff"]
    end
  end

  describe "caching" do
    test "marks a logo immutable with a strong etag from its SHA-256", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")
      sha256 = :sha256 |> :crypto.hash(@png) |> Base.encode16(case: :lower)

      result = call(logo.path)

      assert get_resp_header(result, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(result, "etag") == [~s("#{sha256}")]
    end

    test "answers a matching if-none-match with 304 and no content", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")
      [etag] = get_resp_header(call(logo.path), "etag")

      result =
        conn(:get, logo.path) |> put_req_header("if-none-match", etag) |> UploadedFiles.call([])

      assert result.halted
      assert result.status == 304
      assert result.resp_body == ""
      assert get_resp_header(result, "etag") == [etag]
      assert get_resp_header(result, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "does not read the content to answer 304", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")
      drop_chunks(logo.stored)

      result =
        conn(:get, logo.path)
        |> put_req_header("if-none-match", ~s("#{logo.stored.sha256}"))
        |> UploadedFiles.call([])

      # Reading would have found the content gone and passed the request on.
      assert result.status == 304
    end

    test "matches a weak tag, a list of tags and *", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")
      etag = ~s("#{logo.stored.sha256}")

      for value <- ["W/" <> etag, ~s("other", ) <> etag, "*"] do
        result =
          conn(:get, logo.path)
          |> put_req_header("if-none-match", value)
          |> UploadedFiles.call([])

        assert result.status == 304, "expected #{value} to match"
      end
    end

    test "serves the content when if-none-match names another tag", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      result =
        conn(:get, logo.path)
        |> put_req_header("if-none-match", ~s("#{String.duplicate("0", 64)}"))
        |> UploadedFiles.call([])

      assert result.status == 200
      assert result.resp_body == @png
    end
  end

  describe "corrupt content" do
    test "passes the request through unchanged when a chunk is missing", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")
      drop_chunks(logo.stored)
      request = conn(:get, logo.path)

      assert UploadedFiles.call(request, []) == request
    end

    test "passes the request through unchanged when the content does not match its hash",
         %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      Repo.update_all(from(c in Chunk, where: c.file_id == ^logo.stored.id),
        set: [data: String.duplicate("x", byte_size(@png))]
      )

      request = conn(:get, logo.path)

      assert UploadedFiles.call(request, []) == request
    end
  end

  describe "security attack scenarios" do
    test "rejects null byte injection attempts" do
      # The extension after the null byte is the one that counts
      result = call("/uploads/image.png\x00.html")

      assert result.halted
      assert result.status == 403
    end

    test "rejects semicolon extension bypass attempts" do
      result = call("/uploads/image.png;.html")

      # Extension is ".html" so should be rejected
      assert result.halted
      assert result.status == 403
    end
  end

  describe "through the endpoint" do
    test "a logo is served without a session, on any host", %{tenant: tenant} do
      logo = store_logo(tenant, ".png")

      conn = get(%{build_conn() | host: "elsewhere.example.com"}, logo.path)

      assert response(conn, 200) == @png
      assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["script-src 'none'"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "etag") == [~s("#{logo.stored.sha256}")]
    end

    test "an unknown key is a 404 from the router", %{conn: conn} do
      assert get(conn, "/uploads/logos/#{Ecto.UUID.generate()}.png").status == 404
    end

    test "a deleted logo is a 404 from the router", %{conn: conn, tenant: tenant} do
      logo = store_logo(tenant, ".png")
      :ok = Files.delete(tenant.id, :logo, logo.key)

      assert get(conn, logo.path).status == 404
    end

    test "traversal and a disallowed extension are refused before the router", %{conn: conn} do
      assert response(get(conn, "/uploads/logos/%2e%2e/secret.png"), 400) == "Invalid path"
      assert response(get(conn, "/uploads/logos/page.html"), 403) == "File type not allowed"
    end
  end

  # In these modes the Repo is not running (Custyard.Application). The boot
  # gate sits ahead of this plug and answers, so the lookup never happens.
  describe "while the Repo is not started" do
    setup %{tenant: tenant} do
      State.reset()
      handler = "uploaded-files-test-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:custyard, :repo, :query], &__MODULE__.report_query/4, self())

      on_exit(fn ->
        :telemetry.detach(handler)
        State.reset()
      end)

      %{logo: store_logo(tenant, ".png")}
    end

    def report_query(_event, _measurements, _metadata, test_pid), do: send(test_pid, :repo_query)

    defp set_mode(mode) do
      State.put(%State{
        mode: mode,
        env: Env.read(%{}, config_env: :prod),
        booted_at: ~U[2026-11-03 21:14:08Z]
      })
    end

    defp flush_repo_queries do
      receive do
        :repo_query -> flush_repo_queries()
      after
        0 -> :ok
      end
    end

    for {mode, card} <- [
          unconfigured: "boot-card-unconfigured",
          starting: "boot-card-starting",
          database_unavailable: "boot-card-database"
        ] do
      test "#{mode}: a logo request gets the boot card and runs no query",
           %{conn: conn, logo: logo} do
        set_mode(unquote(mode))
        flush_repo_queries()

        conn = get(conn, logo.path)

        assert html_response(conn, 503) =~ ~s(data-testid="#{unquote(card)}")
        assert conn.halted
        assert get_resp_header(conn, "etag") == []
        refute_received :repo_query
      end
    end

    test "ready: the same request reaches the Repo", %{conn: conn, logo: logo} do
      assert State.mode() == :ready
      flush_repo_queries()

      assert response(get(conn, logo.path), 200) == @png
      assert_received :repo_query
    end
  end
end

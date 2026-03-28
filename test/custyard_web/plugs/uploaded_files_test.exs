defmodule CustyardWeb.Plugs.UploadedFilesTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CustyardWeb.Plugs.UploadedFiles

  @test_upload_dir "/tmp/custyard_test_uploads"

  setup do
    # Create a temporary upload directory for tests
    File.rm_rf!(@test_upload_dir)
    File.mkdir_p!(@test_upload_dir)

    # Set up test configuration
    original_upload_dir = Application.get_env(:custyard, :upload_dir)
    Application.put_env(:custyard, :upload_dir, @test_upload_dir)

    on_exit(fn ->
      # Restore original config
      if original_upload_dir do
        Application.put_env(:custyard, :upload_dir, original_upload_dir)
      else
        Application.delete_env(:custyard, :upload_dir)
      end

      # Clean up test files
      File.rm_rf!(@test_upload_dir)
    end)

    :ok
  end

  describe "init/1" do
    test "returns options unchanged" do
      opts = [some: :option]
      assert UploadedFiles.init(opts) == opts
    end
  end

  describe "call/2 path matching" do
    test "passes through non-upload paths" do
      conn = conn(:get, "/other/path")

      result = UploadedFiles.call(conn, [])

      refute result.halted
      refute result.status
    end

    test "handles /uploads/ prefix" do
      # Create a test file
      create_test_file("test.png", "PNG content")

      conn = conn(:get, "/uploads/test.png")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 200
    end

    test "passes through when upload_dir is not configured" do
      Application.delete_env(:custyard, :upload_dir)

      conn = conn(:get, "/uploads/test.png")

      result = UploadedFiles.call(conn, [])

      refute result.halted
    end
  end

  describe "path traversal protection" do
    test "rejects paths with .." do
      conn = conn(:get, "/uploads/../../../etc/passwd")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects paths with .. in subdirectory" do
      conn = conn(:get, "/uploads/subdir/../secret.png")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects URL-encoded traversal (lowercase)" do
      # %2e%2e is URL-encoded ".."
      conn = conn(:get, "/uploads/%2e%2e/secret.png")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects URL-encoded traversal (uppercase)" do
      # %2E%2E is URL-encoded ".."
      conn = conn(:get, "/uploads/%2E%2E/secret.png")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 400
      assert result.resp_body == "Invalid path"
    end

    test "rejects mixed encoded traversal" do
      # Mix of encoded and plain
      conn = conn(:get, "/uploads/foo/%2e%2e/bar/%2E%2E/secret.png")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 400
    end

    test "allows paths with single dots" do
      # Single dots in filenames are fine
      create_test_file("file.name.png", "PNG content")

      conn = conn(:get, "/uploads/file.name.png")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end
  end

  describe "extension allowlist validation" do
    test "allows .png files" do
      create_test_file("image.png", "PNG")

      conn = conn(:get, "/uploads/image.png")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows .jpg files" do
      create_test_file("image.jpg", "JPG")

      conn = conn(:get, "/uploads/image.jpg")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows .jpeg files" do
      create_test_file("image.jpeg", "JPEG")

      conn = conn(:get, "/uploads/image.jpeg")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows .gif files" do
      create_test_file("image.gif", "GIF")

      conn = conn(:get, "/uploads/image.gif")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows .webp files" do
      create_test_file("image.webp", "WEBP")

      conn = conn(:get, "/uploads/image.webp")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows .svg files" do
      create_test_file("logo.svg", "<svg></svg>")

      conn = conn(:get, "/uploads/logo.svg")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows uppercase extensions" do
      create_test_file("IMAGE.PNG", "PNG")

      conn = conn(:get, "/uploads/IMAGE.PNG")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "allows mixed case extensions" do
      create_test_file("image.JpEg", "JPEG")

      conn = conn(:get, "/uploads/image.JpEg")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "rejects .html files" do
      conn = conn(:get, "/uploads/malicious.html")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 403
      assert result.resp_body == "File type not allowed"
    end

    test "rejects .js files" do
      conn = conn(:get, "/uploads/script.js")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 403
      assert result.resp_body == "File type not allowed"
    end

    test "rejects .exe files" do
      conn = conn(:get, "/uploads/virus.exe")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 403
    end

    test "rejects .php files" do
      conn = conn(:get, "/uploads/shell.php")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 403
    end

    test "rejects files without extension" do
      conn = conn(:get, "/uploads/noextension")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 403
    end

    test "rejects double extension attacks" do
      # Attacker might try to sneak past with image.png.html
      conn = conn(:get, "/uploads/image.png.html")

      result = UploadedFiles.call(conn, [])

      assert result.halted
      assert result.status == 403
    end
  end

  describe "MIME type handling" do
    test "sets correct Content-Type for PNG" do
      create_test_file("test.png", "PNG content")

      conn = conn(:get, "/uploads/test.png")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-type") == ["image/png; charset=utf-8"]
    end

    test "sets correct Content-Type for JPEG" do
      create_test_file("test.jpg", "JPEG content")

      conn = conn(:get, "/uploads/test.jpg")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-type") == ["image/jpeg; charset=utf-8"]
    end

    test "sets correct Content-Type for SVG" do
      create_test_file("test.svg", "<svg></svg>")

      conn = conn(:get, "/uploads/test.svg")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-type") == ["image/svg+xml; charset=utf-8"]
    end

    test "sets correct Content-Type for GIF" do
      create_test_file("test.gif", "GIF content")

      conn = conn(:get, "/uploads/test.gif")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-type") == ["image/gif; charset=utf-8"]
    end

    test "sets correct Content-Type for WebP" do
      create_test_file("test.webp", "WebP content")

      conn = conn(:get, "/uploads/test.webp")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-type") == ["image/webp; charset=utf-8"]
    end
  end

  describe "Content-Disposition header" do
    test "does not add Content-Disposition for PNG (safe inline)" do
      create_test_file("test.png", "PNG content")

      conn = conn(:get, "/uploads/test.png")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-disposition") == []
    end

    test "does not add Content-Disposition for JPEG (safe inline)" do
      create_test_file("test.jpg", "JPEG content")

      conn = conn(:get, "/uploads/test.jpg")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-disposition") == []
    end

    test "does not add Content-Disposition for GIF (safe inline)" do
      create_test_file("test.gif", "GIF content")

      conn = conn(:get, "/uploads/test.gif")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-disposition") == []
    end

    test "does not add Content-Disposition for WebP (safe inline)" do
      create_test_file("test.webp", "WebP content")

      conn = conn(:get, "/uploads/test.webp")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-disposition") == []
    end

    test "does not add Content-Disposition for SVG (safe inline)" do
      create_test_file("test.svg", "<svg></svg>")

      conn = conn(:get, "/uploads/test.svg")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "content-disposition") == []
    end
  end

  describe "CSP headers for SVG files" do
    test "adds script-src none CSP header for SVG" do
      create_test_file("logo.svg", "<svg></svg>")

      conn = conn(:get, "/uploads/logo.svg")

      result = UploadedFiles.call(conn, [])

      csp = get_resp_header(result, "content-security-policy")
      assert csp == ["script-src 'none'"]
    end

    test "adds CSP header for all served files" do
      # CSP is added to all files for defense in depth
      create_test_file("test.png", "PNG content")

      conn = conn(:get, "/uploads/test.png")

      result = UploadedFiles.call(conn, [])

      csp = get_resp_header(result, "content-security-policy")
      assert csp == ["script-src 'none'"]
    end
  end

  describe "X-Content-Type-Options header" do
    test "adds nosniff header" do
      create_test_file("test.png", "PNG content")

      conn = conn(:get, "/uploads/test.png")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end

    test "prevents MIME type sniffing for SVG" do
      create_test_file("test.svg", "<svg><script>alert(1)</script></svg>")

      conn = conn(:get, "/uploads/test.svg")

      result = UploadedFiles.call(conn, [])

      assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
    end
  end

  describe "file serving" do
    test "returns 200 for existing file" do
      create_test_file("exists.png", "file content")

      conn = conn(:get, "/uploads/exists.png")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end

    test "passes through for non-existent file" do
      conn = conn(:get, "/uploads/doesnotexist.png")

      result = UploadedFiles.call(conn, [])

      # Should not halt, allowing downstream handlers to deal with 404
      refute result.halted
    end

    test "serves files from subdirectories" do
      File.mkdir_p!(Path.join(@test_upload_dir, "subdir"))
      create_test_file("subdir/nested.png", "nested content")

      conn = conn(:get, "/uploads/subdir/nested.png")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end
  end

  describe "security attack scenarios" do
    test "rejects null byte injection attempts" do
      # Some systems might truncate at null byte
      conn = conn(:get, "/uploads/image.png\x00.html")

      result = UploadedFiles.call(conn, [])

      # Should reject - the extension check will see .html after null byte
      # or the null byte itself makes it an invalid extension
      assert result.halted
      assert result.status == 403
    end

    test "rejects semicolon extension bypass attempts" do
      conn = conn(:get, "/uploads/image.png;.html")

      result = UploadedFiles.call(conn, [])

      # Extension is ".html" so should be rejected
      assert result.halted
      assert result.status == 403
    end

    test "handles filenames with spaces" do
      # The plug receives the path already decoded by Phoenix router
      # so the file on disk and the request path should match
      create_test_file("my image.png", "PNG")

      conn = conn(:get, "/uploads/my image.png")

      result = UploadedFiles.call(conn, [])

      assert result.status == 200
    end
  end

  # Helper to create test files
  defp create_test_file(name, content) do
    path = Path.join(@test_upload_dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end

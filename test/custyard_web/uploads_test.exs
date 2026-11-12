defmodule CustyardWeb.UploadsTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Files
  alias Custyard.Files.StoredFile
  alias CustyardWeb.Uploads

  @moduletag :tmp_dir

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "logo bytes">>

  setup do
    %{tenant: insert_tenant()}
  end

  defp temp_file(tmp_dir, bytes) do
    path = Path.join(tmp_dir, "upload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    path
  end

  defp logo_count, do: Repo.aggregate(from(f in StoredFile, where: f.kind == :logo), :count)

  describe "save_logo/3" do
    test "stores the file under the tenant and returns its public path",
         %{tenant: tenant, tmp_dir: tmp_dir} do
      assert {:ok, "/uploads/logos/" <> key = path} =
               Uploads.save_logo(tenant.id, temp_file(tmp_dir, @png), "Our Logo.png")

      assert Custyard.UploadPath.valid?(path)
      assert {:ok, _uuid} = Ecto.UUID.cast(Path.rootname(key))
      assert Path.extname(key) == ".png"

      assert %StoredFile{tenant_id: tenant_id, size: size} = stored = Files.get_public(:logo, key)
      assert tenant_id == tenant.id
      assert size == byte_size(@png)
      assert Files.read(stored) == {:ok, @png}
      assert Files.get(tenant.id, :logo, key)
      refute Files.get(insert_tenant().id, :logo, key)
    end

    test "lowercases the extension in the key", %{tenant: tenant, tmp_dir: tmp_dir} do
      assert {:ok, "/uploads/logos/" <> key} =
               Uploads.save_logo(tenant.id, temp_file(tmp_dir, @png), "LOGO.PNG")

      assert Path.extname(key) == ".png"
      assert Files.get(tenant.id, :logo, key)
    end

    test "accepts every extension the upload form accepts", %{tenant: tenant, tmp_dir: tmp_dir} do
      source = temp_file(tmp_dir, @png)

      for ext <- Uploads.logo_extensions() do
        assert {:ok, path} = Uploads.save_logo(tenant.id, source, "logo" <> ext)
        assert String.ends_with?(path, ext)
      end

      assert Uploads.logo_extensions() == ~w(.png .jpg .jpeg .svg .webp)
    end

    test "gives each upload its own key, even for identical content",
         %{tenant: tenant, tmp_dir: tmp_dir} do
      source = temp_file(tmp_dir, @png)

      assert {:ok, first} = Uploads.save_logo(tenant.id, source, "logo.png")
      assert {:ok, second} = Uploads.save_logo(tenant.id, source, "logo.png")
      assert first != second
    end

    test "refuses an extension outside the allowlist and stores nothing",
         %{tenant: tenant, tmp_dir: tmp_dir} do
      source = temp_file(tmp_dir, "<script>alert(1)</script>")

      for name <- ~w(page.html logo.gif logo.png.exe logo .png) ++ [""] do
        assert Uploads.save_logo(tenant.id, source, name) == {:error, :not_accepted},
               "expected #{inspect(name)} to be refused"
      end

      assert logo_count() == 0
    end

    test "refuses a file over the size bound and stores nothing",
         %{tenant: tenant, tmp_dir: tmp_dir} do
      assert Uploads.max_logo_bytes() == 2_000_000
      source = temp_file(tmp_dir, :binary.copy(<<0>>, Uploads.max_logo_bytes() + 1))

      assert Uploads.save_logo(tenant.id, source, "logo.png") == {:error, :too_large}
      assert logo_count() == 0
    end

    test "accepts a file of exactly the size bound", %{tenant: tenant, tmp_dir: tmp_dir} do
      bytes = :binary.copy(<<7>>, Uploads.max_logo_bytes())

      assert {:ok, "/uploads/logos/" <> key} =
               Uploads.save_logo(tenant.id, temp_file(tmp_dir, bytes), "logo.png")

      assert Files.read(Files.get(tenant.id, :logo, key)) == {:ok, bytes}
    end
  end

  describe "delete_logo/2" do
    setup %{tenant: tenant, tmp_dir: tmp_dir} do
      {:ok, "/uploads/logos/" <> key = path} =
        Uploads.save_logo(tenant.id, temp_file(tmp_dir, @png), "logo.png")

      %{path: path, key: key}
    end

    test "removes the tenant's own logo", %{tenant: tenant, path: path, key: key} do
      assert Uploads.delete_logo(tenant.id, path) == :ok
      refute Files.get_public(:logo, key)
      assert logo_count() == 0
    end

    test "leaves another tenant's logo in place", %{tenant: tenant, path: path, key: key} do
      other = insert_tenant()

      assert Uploads.delete_logo(other.id, path) == :ok

      assert %StoredFile{} = stored = Files.get(tenant.id, :logo, key)
      assert Files.read(stored) == {:ok, @png}
    end

    test "finds the key for a path with an uppercase extension",
         %{tenant: tenant, path: path, key: key} do
      assert Uploads.delete_logo(tenant.id, String.replace_suffix(path, ".png", ".PNG")) == :ok
      refute Files.get(tenant.id, :logo, key)
    end

    test "ignores paths that do not name a logo", %{tenant: tenant, key: key} do
      for path <- [
            nil,
            "",
            "/uploads/logos/",
            "/uploads/#{key}",
            "/uploads/other/#{key}",
            "/uploads/logos/../logos/#{key}",
            "/uploads/logos/sub/#{key}",
            "/uploads/logos/.#{key}",
            "https://example.com/uploads/logos/#{key}"
          ] do
        assert Uploads.delete_logo(tenant.id, path) == :ok
      end

      assert Files.get(tenant.id, :logo, key)
    end

    test "is :ok when the logo is already gone", %{tenant: tenant, path: path} do
      assert Uploads.delete_logo(tenant.id, path) == :ok
      assert Uploads.delete_logo(tenant.id, path) == :ok
    end
  end

  describe "logo_key/1" do
    test "is the filename with its extension lowercased" do
      uuid = Ecto.UUID.generate()

      assert Uploads.logo_key(uuid <> ".png") == {:ok, uuid <> ".png"}
      assert Uploads.logo_key(uuid <> ".PNG") == {:ok, uuid <> ".png"}
      assert Uploads.logo_key("Brand.Mark.JpEg") == {:ok, "Brand.Mark.jpeg"}
    end

    test "is :error for a name the file store would not accept as a key" do
      for name <- ["", ".png", "sub/logo.png", "my logo.png", "-logo.png", "logo.png\0"] do
        assert Uploads.logo_key(name) == :error, "expected #{inspect(name)} to be refused"
      end

      assert Uploads.logo_key(String.duplicate("a", 252) <> ".png") == :error
      assert {:ok, _} = Uploads.logo_key(String.duplicate("a", 251) <> ".png")
    end
  end
end

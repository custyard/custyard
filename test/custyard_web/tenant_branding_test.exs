defmodule CustyardWeb.TenantBrandingTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Custyard.{Files, Repo, Tenants}
  alias Custyard.Files.StoredFile
  alias CustyardWeb.Uploads

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @svg ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|

  setup %{conn: conn} do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Atlas Support",
        slug: "branding-#{System.unique_integer([:positive])}",
        primary_color: "#123456"
      })

    staff = insert_staff_account(role: "admin", organization_id: nil, tenant_id: tenant.id)
    conn = conn |> init_test_session(%{}) |> put_staff_session(staff)
    %{conn: conn, tenant: tenant}
  end

  @tag :tmp_dir
  test "logo uploads preserve the old file on validation failure and replace only after save",
       c do
    source = Path.join(c.tmp_dir, "seed.png")
    File.write!(source, "old logo")
    {:ok, old_url} = Uploads.save_logo(c.tenant.id, source, "old.png")
    {:ok, _} = Tenants.update_tenant(c.tenant, %{logo_url: old_url})
    {:ok, view, html} = live(c.conn, "/app/settings/tenant")
    assert html =~ ~s(content="Atlas Support")
    refute html =~ "/favicon.svg"
    refute has_element?(view, "input[name='tenant[logo_url]']")
    upload_logo(view, "rejected.png")

    view
    |> form("#tenant-settings", %{"tenant" => %{"primary_color" => "invalid"}})
    |> render_submit()

    # The update failed, so the logo stored for it is gone and the old one stays.
    assert Repo.reload!(c.tenant).logo_url == old_url
    assert stored_logo_urls(c.tenant) == [old_url]
    assert stored_content(c.tenant, old_url) == "old logo"

    upload_logo(view, "accepted.png")

    view
    |> form("#tenant-settings", %{
      "tenant" => %{"name" => "Atlas Help", "primary_color" => "#abcdef"}
    })
    |> render_submit()

    saved = Repo.reload!(c.tenant)
    assert saved.name == "Atlas Help"
    assert saved.logo_url != old_url
    # Replaced: the new logo is the tenant's only stored logo.
    assert stored_logo_urls(c.tenant) == [saved.logo_url]
    assert stored_content(c.tenant, saved.logo_url) == @png
    assert get(build_conn(), old_url).status == 404
    assert has_element?(view, "[data-testid=tenant-logo-preview][src='#{saved.logo_url}']")
    view |> form("#tenant-settings", %{"tenant" => %{"remove_logo" => "true"}}) |> render_submit()
    assert Repo.reload!(c.tenant).logo_url == nil
    assert stored_logo_urls(c.tenant) == []
    assert get(build_conn(), saved.logo_url).status == 404
  end

  test "an uploaded logo is stored in the database under the tenant and served as uploaded",
       c do
    {:ok, view, _} = live(c.conn, "/app/settings/tenant")
    upload_logo(view, "Brand Mark.PNG")

    view
    |> form("#tenant-settings", %{"tenant" => %{"name" => "Atlas Support"}})
    |> render_submit()

    assert "/uploads/logos/" <> key = logo_url = Repo.reload!(c.tenant).logo_url
    assert {:ok, _uuid} = Ecto.UUID.cast(Path.rootname(key))
    assert Path.extname(key) == ".png"

    assert %StoredFile{tenant_id: tenant_id} = stored = Files.get_public(:logo, key)
    assert tenant_id == c.tenant.id
    assert Files.read(stored) == {:ok, @png}

    # Public: no session, and not the tenant's host.
    served = get(build_conn(), logo_url)
    assert response(served, 200) == @png
    assert get_resp_header(served, "content-type") == ["image/png; charset=utf-8"]
    assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(served, "content-security-policy") == ["script-src 'none'"]
    assert get_resp_header(served, "content-disposition") == []
    assert get_resp_header(served, "cache-control") == ["public, max-age=31536000, immutable"]
    assert [etag] = get_resp_header(served, "etag")
    assert etag == ~s("#{stored.sha256}")

    revalidated = build_conn() |> put_req_header("if-none-match", etag) |> get(logo_url)
    assert response(revalidated, 304) == ""
    assert get_resp_header(revalidated, "etag") == [etag]
  end

  test "an uploaded SVG logo is served with the script-blocking policy", c do
    {:ok, view, _} = live(c.conn, "/app/settings/tenant")

    view
    |> file_input("#tenant-settings", :logo, [
      %{name: "logo.svg", content: @svg, type: "image/svg+xml"}
    ])
    |> render_upload("logo.svg")

    view
    |> form("#tenant-settings", %{"tenant" => %{"name" => "Atlas Support"}})
    |> render_submit()

    logo_url = Repo.reload!(c.tenant).logo_url
    assert String.ends_with?(logo_url, ".svg")

    served = get(build_conn(), logo_url)
    assert response(served, 200) == @svg
    assert get_resp_header(served, "content-type") == ["image/svg+xml; charset=utf-8"]
    assert get_resp_header(served, "content-security-policy") == ["script-src 'none'"]
    assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
  end

  @tag :tmp_dir
  test "saving one tenant's settings never touches another tenant's logo", c do
    other = insert_tenant()
    source = Path.join(c.tmp_dir, "other.png")
    File.write!(source, "other tenant logo")
    {:ok, other_url} = Uploads.save_logo(other.id, source, "other.png")
    {:ok, _} = Tenants.update_tenant(other, %{logo_url: other_url})

    # This tenant's logo_url names the other tenant's file, as a stale or
    # hand-edited row could. Replacing it must leave that file.
    {:ok, _} = Tenants.update_tenant(c.tenant, %{logo_url: other_url})
    {:ok, view, _} = live(c.conn, "/app/settings/tenant")
    upload_logo(view, "mine.png")

    view
    |> form("#tenant-settings", %{"tenant" => %{"name" => "Atlas Support"}})
    |> render_submit()

    assert Repo.reload!(c.tenant).logo_url != other_url
    assert stored_logo_urls(other) == [other_url]
    assert stored_content(other, other_url) == "other tenant logo"
    assert response(get(build_conn(), other_url), 200) == "other tenant logo"
  end

  test "logo upload rejects unsupported files and shows actionable help", c do
    {:ok, view, _} = live(c.conn, "/app/settings/tenant")

    upload =
      file_input(view, "#tenant-settings", :logo, [
        %{name: "logo.txt", content: "not an image", type: "text/plain"}
      ])

    assert {:error, _} = render_upload(upload, "logo.txt")
    assert render(view) =~ "Use PNG, JPEG, SVG or WebP"
    assert Repo.reload!(c.tenant).logo_url == nil
    assert stored_logo_urls(c.tenant) == []
  end

  test "logo upload rejects a file over 2 MB and stores nothing", c do
    {:ok, view, _} = live(c.conn, "/app/settings/tenant")

    upload =
      file_input(view, "#tenant-settings", :logo, [
        %{name: "big.png", content: :binary.copy(<<0>>, 2_000_001), type: "image/png"}
      ])

    assert {:error, _} = render_upload(upload, "big.png")
    assert render(view) =~ "Logo must be under 2 MB"

    html =
      view |> form("#tenant-settings", %{"tenant" => %{"name" => "Renamed"}}) |> render_submit()

    assert html =~ "Choose a logo under 2 MB and wait for the upload to finish"
    assert Repo.reload!(c.tenant).name == "Atlas Support"
    assert stored_logo_urls(c.tenant) == []
  end

  test "tenant home and login use their branding without default commercial imagery", c do
    {:ok, tenant} = Tenants.update_tenant(c.tenant, %{logo_url: "/uploads/logos/atlas.png"})
    anonymous = %{build_conn() | host: Tenants.host(tenant)}
    {:ok, view, html} = live(anonymous, "/")
    assert has_element?(view, "[data-testid=home-container]", "Welcome to Atlas Support")
    assert has_element?(view, "[data-testid=home-staff-login-link]", "Staff sign in")
    assert html =~ ~s(content="Atlas Support")
    assert html =~ ~s(content="#123456")
    assert html =~ ~s(href="/uploads/logos/atlas.png")
    refute html =~ "/images/og-image.png"
    refute html =~ "/favicon.svg"
    refute html =~ "site.webmanifest"
    refute html =~ ">Custyard<"

    html = anonymous |> get("/app/login") |> html_response(200)
    assert html =~ "Atlas Support"
    assert html =~ "Staff sign in"
    assert html =~ ~s(src="/uploads/logos/atlas.png")
    refute html =~ "/images/og-image.png"
  end

  test "every tenant without a logo uses neutral workspace branding", c do
    html =
      %{build_conn() | host: Tenants.host(c.tenant)}
      |> get("/app/login")
      |> html_response(200)

    assert html =~ ~s(href="data:,")
    refute html =~ "og:image"
    {:ok, _, html} = live(build_conn(), "/")
    assert html =~ "Welcome to Tenant"
    refute html =~ "/favicon.svg"
    refute html =~ "/images/og-image.png"
  end

  defp upload_logo(view, filename) do
    view
    |> file_input("#tenant-settings", :logo, [%{name: filename, content: @png, type: "image/png"}])
    |> render_upload(filename)
  end

  # Public paths of the logos stored in the database for the tenant.
  defp stored_logo_urls(tenant) do
    keys =
      from f in StoredFile,
        where: f.tenant_id == ^tenant.id and f.kind == :logo,
        order_by: f.id,
        select: f.key

    keys |> Repo.all() |> Enum.map(&("/uploads/logos/" <> &1))
  end

  defp stored_content(tenant, "/uploads/logos/" <> key) do
    {:ok, content} = Files.read(Files.get(tenant.id, :logo, key))
    content
  end
end

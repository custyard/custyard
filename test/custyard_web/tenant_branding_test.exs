defmodule CustyardWeb.TenantBrandingTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  import Phoenix.LiveViewTest
  alias Custyard.{Repo, Tenants}
  alias CustyardWeb.Uploads

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

  setup %{conn: conn} do
    original_dir = Application.get_env(:custyard, :upload_dir)

    dir =
      Path.join(
        System.tmp_dir!(),
        "custyard-tenant-branding-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Application.put_env(:custyard, :upload_dir, dir)

    on_exit(fn ->
      Application.put_env(:custyard, :upload_dir, original_dir)
      File.rm_rf!(dir)
    end)

    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Atlas Support",
        slug: "branding-#{System.unique_integer([:positive])}",
        primary_color: "#123456"
      })

    operator = insert_operator_account(role: "admin", organization_id: nil, tenant_id: tenant.id)
    conn = conn |> init_test_session(%{}) |> put_operator_session(operator)
    %{conn: conn, tenant: tenant, dir: dir}
  end

  test "logo uploads preserve the old file on validation failure and replace only after save",
       c do
    source = Path.join(c.dir, "seed.png")
    File.write!(source, @png)
    old_url = Uploads.save_logo(source, "old.png")
    {:ok, _} = Tenants.update_tenant(c.tenant, %{logo_url: old_url})
    old_path = disk_path(c.dir, old_url)
    {:ok, view, html} = live(c.conn, "/app/settings/workspace")
    assert html =~ ~s(content="Atlas Support")
    refute html =~ "/favicon.svg"
    refute has_element?(view, "input[name='tenant[logo_url]']")
    upload_logo(view, "rejected.png")

    view
    |> form("#tenant-settings", %{"tenant" => %{"primary_color" => "invalid"}})
    |> render_submit()

    assert Repo.reload!(c.tenant).logo_url == old_url
    assert File.exists?(old_path)
    assert Path.wildcard(Path.join(c.dir, "logos/*")) == [old_path]

    upload_logo(view, "accepted.png")

    view
    |> form("#tenant-settings", %{
      "tenant" => %{"name" => "Atlas Help", "primary_color" => "#abcdef"}
    })
    |> render_submit()

    saved = Repo.reload!(c.tenant)
    assert saved.name == "Atlas Help"
    assert saved.logo_url != old_url
    assert File.exists?(disk_path(c.dir, saved.logo_url))
    refute File.exists?(old_path)
    assert has_element?(view, "[data-testid=tenant-logo-preview][src='#{saved.logo_url}']")
    view |> form("#tenant-settings", %{"tenant" => %{"remove_logo" => "true"}}) |> render_submit()
    assert Repo.reload!(c.tenant).logo_url == nil
    refute File.exists?(disk_path(c.dir, saved.logo_url))
  end

  test "logo upload rejects unsupported files and shows actionable help", c do
    {:ok, view, _} = live(c.conn, "/app/settings/workspace")

    upload =
      file_input(view, "#tenant-settings", :logo, [
        %{name: "logo.txt", content: "not an image", type: "text/plain"}
      ])

    assert {:error, _} = render_upload(upload, "logo.txt")
    assert render(view) =~ "Use PNG, JPEG, SVG or WebP"
    assert Repo.reload!(c.tenant).logo_url == nil
  end

  test "tenant home and login use their branding without default commercial imagery", c do
    {:ok, tenant} = Tenants.update_tenant(c.tenant, %{logo_url: "/uploads/logos/atlas.png"})
    anonymous = %{build_conn() | host: Tenants.host(tenant)}
    {:ok, view, html} = live(anonymous, "/")
    assert has_element?(view, "[data-testid=home-container]", "Welcome to Atlas Support")
    assert has_element?(view, "[data-testid=home-operator-login-link]", "Staff sign in")
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

  defp disk_path(dir, url), do: Path.join(dir, String.replace_prefix(url, "/uploads/", ""))
end

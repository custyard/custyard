defmodule CustyardWeb.Staff.AttachmentControllerTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory

  alias Custyard.Attachments
  alias Custyard.Attachments.StubClient

  setup %{conn: conn} do
    org = insert_organization()
    conv = insert_thread(organization_id: org.id)
    message = insert_message(thread_id: conv.id)

    url = StubClient.unique_url()
    StubClient.put(url, "<html><script>alert(1)</script></html>")

    {:ok, [attachment]} =
      Attachments.fetch_for_message(message, [
        %{
          filename: "evil page.html",
          content_type: "text/html",
          size: nil,
          content_id: nil,
          url: url
        }
      ])

    %{conn: conn, org: org, attachment: attachment}
  end

  test "downloads as an attachment under the sniffed, allowlisted type", %{
    conn: conn,
    org: org,
    attachment: attachment
  } do
    agent = insert_staff_account(role: "agent", organization_id: org.id)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(agent)
      |> get(~p"/app/attachments/#{attachment.id}")

    assert conn.status == 200
    assert conn.resp_body =~ "alert(1)"
    # The bytes sniff as text/plain; a declared text/html is never trusted and
    # the file is always a download.
    assert get_resp_header(conn, "content-type") == ["text/plain"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "evil%20page.html"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
  end

  test "a staff from another tenant gets 404", %{conn: conn, attachment: attachment} do
    stranger =
      insert_staff_account(
        role: "agent",
        organization_id: insert_organization(tenant_id: insert_tenant().id).id
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(stranger)
      |> get(~p"/app/attachments/#{attachment.id}")

    assert conn.status == 404
  end

  test "unknown ids are 404", %{conn: conn} do
    staff = insert_staff_account(role: "admin")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff)

    assert get(conn, ~p"/app/attachments/999999").status == 404
    assert get(conn, "/app/attachments/not-an-id").status == 404
  end

  test "an anonymous request is sent to login", %{conn: conn, attachment: attachment} do
    conn = get(conn, ~p"/app/attachments/#{attachment.id}")
    assert redirected_to(conn) == "/app/login"
  end

  describe "inline/2" do
    setup %{conn: conn, org: org} do
      conv = insert_thread(organization_id: org.id)
      message = insert_message(thread_id: conv.id)
      url = StubClient.unique_url()
      StubClient.put(url, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>)

      {:ok, [image]} =
        Attachments.fetch_for_message(message, [
          %{filename: "logo.png", content_type: "image/png", content_id: "logo@acme", url: url}
        ])

      agent = insert_staff_account(role: "agent", organization_id: org.id)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(agent)

      %{conn: conn, image: image}
    end

    test "serves a raster image inline", %{conn: conn, image: image} do
      conn = get(conn, ~p"/app/attachments/#{image.id}/inline")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end

    test "refuses anything that is not a raster image", %{conn: conn, attachment: attachment} do
      assert get(conn, ~p"/app/attachments/#{attachment.id}/inline").status == 404
    end

    test "refuses another tenant's image", %{image: image} do
      stranger =
        insert_staff_account(
          role: "agent",
          organization_id: insert_organization(tenant_id: insert_tenant().id).id
        )

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(stranger)
        |> get(~p"/app/attachments/#{image.id}/inline")

      assert conn.status == 404
    end
  end
end

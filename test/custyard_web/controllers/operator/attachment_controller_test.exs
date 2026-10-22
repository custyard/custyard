defmodule CustyardWeb.Operator.AttachmentControllerTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory

  alias Custyard.Attachments
  alias Custyard.Attachments.StubClient

  setup %{conn: conn} do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id)
    message = insert_message(conversation_id: conv.id)

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
    agent = insert_operator_account(role: "agent", organization_id: org.id)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(agent)
      |> get(~p"/operator/attachments/#{attachment.id}")

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

  test "an operator from another organization gets 404", %{conn: conn, attachment: attachment} do
    stranger = insert_operator_account(role: "agent", organization_id: insert_organization().id)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(stranger)
      |> get(~p"/operator/attachments/#{attachment.id}")

    assert conn.status == 404
  end

  test "unknown ids are 404", %{conn: conn} do
    operator = insert_operator_account(role: "super_admin")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(operator)

    assert get(conn, ~p"/operator/attachments/999999").status == 404
    assert get(conn, "/operator/attachments/not-an-id").status == 404
  end

  test "an anonymous request is sent to login", %{conn: conn, attachment: attachment} do
    conn = get(conn, ~p"/operator/attachments/#{attachment.id}")
    assert redirected_to(conn) == "/operator/login"
  end

  describe "inline/2" do
    setup %{conn: conn, org: org} do
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id)
      url = StubClient.unique_url()
      StubClient.put(url, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>)

      {:ok, [image]} =
        Attachments.fetch_for_message(message, [
          %{filename: "logo.png", content_type: "image/png", content_id: "logo@acme", url: url}
        ])

      agent = insert_operator_account(role: "agent", organization_id: org.id)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_operator_session(agent)

      %{conn: conn, image: image}
    end

    test "serves a raster image inline", %{conn: conn, image: image} do
      conn = get(conn, ~p"/operator/attachments/#{image.id}/inline")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end

    test "refuses anything that is not a raster image", %{conn: conn, attachment: attachment} do
      assert get(conn, ~p"/operator/attachments/#{attachment.id}/inline").status == 404
    end

    test "refuses another organization's image", %{image: image} do
      stranger = insert_operator_account(role: "agent", organization_id: insert_organization().id)

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_operator_session(stranger)
        |> get(~p"/operator/attachments/#{image.id}/inline")

      assert conn.status == 404
    end
  end
end

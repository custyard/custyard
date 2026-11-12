defmodule CustyardWeb.Staff.AttachmentControllerTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{Attachments, Files, Repo}
  alias Custyard.Attachments.StubClient
  alias Custyard.Auth.Account
  alias Custyard.Files.Chunk

  @html "<html><script>alert(1)</script></html>"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>

  setup %{conn: conn} do
    org = insert_organization()
    conv = insert_thread(organization_id: org.id)
    message = insert_message(thread_id: conv.id)

    url = StubClient.unique_url()
    StubClient.put(url, @html)

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

    %{conn: conn, org: org, conv: conv, attachment: attachment}
  end

  defp signed_in(conn, org) do
    agent = insert_staff_account(role: "agent", organization_id: org.id)
    conn |> Phoenix.ConnTest.init_test_session(%{}) |> put_staff_session(agent)
  end

  defp drop_chunks(attachment) do
    file = Attachments.stored_file(attachment)
    Repo.delete_all(from c in Chunk, where: c.file_id == ^file.id)
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
    assert conn.resp_body == @html
    # The bytes sniff as text/plain; a declared text/html is never trusted and
    # the file is always a download.
    assert get_resp_header(conn, "content-type") == ["text/plain"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="evil%20page.html"; filename*=utf-8''evil%20page.html)
           ]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  # Larger than one part of the stream and many chunks in the database.
  test "a multi-megabyte attachment downloads byte for byte", %{
    conn: conn,
    org: org,
    conv: conv
  } do
    bytes = :crypto.strong_rand_bytes(3 * 1_048_576 + 4097)

    {:ok, [large]} =
      Attachments.fetch_for_message(insert_message(thread_id: conv.id), [
        %{filename: "backup.bin", content: bytes}
      ])

    assert large.size == byte_size(bytes)
    assert Attachments.stored_file(large).chunk_count == 13

    conn = conn |> signed_in(org) |> get(~p"/app/attachments/#{large.id}")

    assert conn.status == 200
    assert byte_size(conn.resp_body) == byte_size(bytes)
    assert conn.resp_body == bytes
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end

  test "an attachment whose stored content is gone is the same 404", %{
    conn: conn,
    org: org,
    attachment: attachment
  } do
    conn = signed_in(conn, org)
    assert get(conn, ~p"/app/attachments/#{attachment.id}").status == 200

    :ok = Files.delete(attachment.tenant_id, :attachment, attachment.sha256)

    gone = get(conn, ~p"/app/attachments/#{attachment.id}")
    assert gone.status == 404
    assert gone.resp_body == "Not found"
    assert get_resp_header(gone, "content-disposition") == []
    assert gone.resp_body == get(conn, ~p"/app/attachments/999999").resp_body
  end

  test "an attachment whose stored file has lost its content is 404, not an empty 200", %{
    conn: conn,
    org: org,
    attachment: attachment
  } do
    drop_chunks(attachment)

    conn = conn |> signed_in(org) |> get(~p"/app/attachments/#{attachment.id}")
    assert conn.status == 404
    assert conn.resp_body == "Not found"
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

  test "a revoked staff session loses existing download access", %{
    conn: conn,
    attachment: attachment
  } do
    staff = insert_staff_account(role: "admin")
    conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> put_staff_session(staff)
    assert get(conn, ~p"/app/attachments/#{attachment.id}").status == 200

    staff
    |> Ecto.Changeset.change(session_claim: Account.generate_session_claim())
    |> Repo.update!()

    assert conn |> get(~p"/app/attachments/#{attachment.id}") |> redirected_to() == "/app/login"
  end

  describe "inline/2" do
    setup %{conn: conn, org: org} do
      conv = insert_thread(organization_id: org.id)
      message = insert_message(thread_id: conv.id)
      url = StubClient.unique_url()
      StubClient.put(url, @png)

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
      assert conn.resp_body == @png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="logo.png")]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "an image whose stored content is gone is 404", %{conn: conn, image: image} do
      :ok = Files.delete(image.tenant_id, :attachment, image.sha256)
      assert get(conn, ~p"/app/attachments/#{image.id}/inline").status == 404
    end

    test "an image whose stored file has lost its content is 404", %{conn: conn, image: image} do
      drop_chunks(image)
      assert get(conn, ~p"/app/attachments/#{image.id}/inline").status == 404
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

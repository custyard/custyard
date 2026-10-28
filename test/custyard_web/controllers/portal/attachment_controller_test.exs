defmodule CustyardWeb.Portal.AttachmentControllerTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Phoenix.LiveViewTest

  alias Custyard.Attachments
  alias Custyard.Attachments.StubClient
  alias Custyard.Repo

  setup do
    org = insert_organization()
    {:ok, _} = Custyard.Tenants.add_host(org.tenant_id, "portal.acme.test")
    conv = insert_conversation(organization_id: org.id)
    message = insert_message(conversation_id: conv.id, body: "Invoice attached")
    %{org: org, conv: conv, attachment: fetched_attachment(message)}
  end

  defp fetched_attachment(message) do
    url = StubClient.unique_url()
    StubClient.put(url, "<html><script>alert(1)</script></html>")

    {:ok, [attachment]} =
      Attachments.fetch_for_message(message, [
        %{filename: "invoice.html", content_type: "text/html", size: nil, url: url}
      ])

    attachment
  end

  describe "GET /p/:org_token/attachments/:id" do
    test "downloads under the sniffed type, never inline", %{
      conn: conn,
      org: org,
      attachment: attachment
    } do
      conn = get(conn, "/portal/#{portal_token(org)}/attachments/#{attachment.id}")

      assert conn.status == 200
      assert conn.resp_body =~ "alert(1)"
      assert get_resp_header(conn, "content-type") == ["text/plain"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end

    test "is reachable on the tenant's registered custom domain", %{
      conn: conn,
      attachment: attachment,
      org: org
    } do
      conn =
        %{conn | host: "portal.acme.test"}
        |> get("/portal/#{portal_token(org)}/attachments/#{attachment.id}")

      assert conn.status == 200
      assert conn.resp_body =~ "alert(1)"
    end

    test "another organization's portal gets 404", %{conn: conn, attachment: attachment} do
      other = insert_organization()

      assert get(conn, "/portal/#{portal_token(other)}/attachments/#{attachment.id}").status ==
               404
    end

    test "unknown and malformed ids are 404", %{conn: conn, org: org} do
      assert get(conn, "/portal/#{portal_token(org)}/attachments/999999").status == 404
      assert get(conn, "/portal/#{portal_token(org)}/attachments/not-an-id").status == 404
    end

    test "the root path on the app host is 404", %{conn: conn, attachment: attachment} do
      assert get(conn, "/attachments/#{attachment.id}").status == 404
    end
  end

  describe "Attachments.get_for_portal/2" do
    test "returns a fetched attachment of the organization", %{org: org, attachment: attachment} do
      assert Attachments.get_for_portal(attachment.id, org.id).id == attachment.id
    end

    test "refuses internal notes, deleted messages and suspect conversations", %{org: org} do
      conv = insert_conversation(organization_id: org.id)
      note = fetched_attachment(insert_message(conversation_id: conv.id, is_internal_note: true))

      deleted_message = insert_message(conversation_id: conv.id)
      deleted = fetched_attachment(deleted_message)

      deleted_message
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
      |> Repo.update!()

      suspect_conv = insert_conversation(organization_id: org.id, suspect: true)
      suspect = fetched_attachment(insert_message(conversation_id: suspect_conv.id))

      for attachment <- [note, deleted, suspect] do
        assert Attachments.get_for_portal(attachment.id, org.id) == nil
      end
    end

    test "refuses an attachment that was not fetched", %{org: org, conv: conv} do
      message = insert_message(conversation_id: conv.id)

      {:ok, [skipped]} =
        Attachments.fetch_for_message(
          message,
          [%{filename: "big.bin", url: StubClient.unique_url()}],
          skip: "suspect"
        )

      assert Attachments.get_for_portal(skipped.id, org.id) == nil
    end
  end

  describe "portal thread" do
    test "links each downloadable attachment under its message", %{
      conn: conn,
      org: org,
      conv: conv,
      attachment: attachment
    } do
      {:ok, view, _html} = live(conn, "/portal/#{portal_token(org)}/request/#{conv.id}")

      assert view
             |> element(~s([data-testid="portal-attachment-#{attachment.id}"]))
             |> render() =~ ~s(href="/portal/#{portal_token(org)}/attachments/#{attachment.id}")
    end

    test "keeps the credential prefix on a tenant custom domain", %{
      conn: conn,
      conv: conv,
      attachment: attachment,
      org: org
    } do
      {:ok, view, _html} =
        live(
          %{conn | host: "portal.acme.test"},
          "/portal/#{portal_token(org)}/request/#{conv.id}"
        )

      assert view
             |> element(~s([data-testid="portal-attachment-#{attachment.id}"]))
             |> render() =~ ~s(href="/portal/#{portal_token(org)}/attachments/#{attachment.id}")
    end

    test "lists nothing under a deleted message", %{conn: conn, org: org, conv: conv} do
      Custyard.Message
      |> Repo.get_by!(conversation_id: conv.id)
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
      |> Repo.update!()

      {:ok, view, _html} = live(conn, "/portal/#{portal_token(org)}/request/#{conv.id}")

      assert has_element?(view, ~s([data-testid="portal-message-tombstone"]))
      refute has_element?(view, ~s([data-testid="portal-message-attachments"]))
    end

    test "lists nothing while the conversation is suspect", %{conn: conn, org: org, conv: conv} do
      conv |> Ecto.Changeset.change(suspect: true) |> Repo.update!()

      {:ok, view, _html} = live(conn, "/portal/#{portal_token(org)}/request/#{conv.id}")

      refute has_element?(view, ~s([data-testid="portal-message-attachments"]))
    end
  end
end

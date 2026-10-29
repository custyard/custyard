defmodule CustyardWeb.Portal.SecurityBoundariesTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Phoenix.LiveViewTest

  alias Custyard.{PortalCredentials, Repo}

  test "open request rechecks customer ownership on every message refresh", %{conn: conn} do
    for event <- [:message_added, :message_updated] do
      customer = insert_organization()
      other = insert_organization()
      thread = insert_thread(organization_id: customer.id)
      token = portal_token(customer)
      {:ok, view, _} = live(conn, "/portal/#{token}/request/#{thread.id}")

      thread |> Ecto.Changeset.change(organization_id: other.id) |> Repo.update!()
      insert_message(thread_id: thread.id, body: "Other customer confidential reply")
      send(view.pid, {event, thread.id})

      assert_redirect(view, "/portal/#{token}")
    end
  end

  test "revoked credential stops an already open request before writing", %{conn: conn} do
    customer = insert_organization()
    thread = insert_thread(organization_id: customer.id)
    scope = portal_scope(customer)
    {:ok, credential, token} = PortalCredentials.issue(scope, customer.id)
    {:ok, view, _} = live(conn, "/portal/#{token}/request/#{thread.id}")
    {:ok, _} = PortalCredentials.revoke(scope, credential)

    render_submit(view, "submit_reply", %{"body" => "Must never be saved"})

    assert_redirect(view, "/")
    refute Repo.get_by(Custyard.Message, thread_id: thread.id, body: "Must never be saved")
  end

  test "revoked credential stops an open request before processing pushed content", %{conn: conn} do
    customer = insert_organization()
    thread = insert_thread(organization_id: customer.id)
    scope = portal_scope(customer)
    {:ok, credential, token} = PortalCredentials.issue(scope, customer.id)
    {:ok, view, _} = live(conn, "/portal/#{token}/request/#{thread.id}")
    {:ok, _} = PortalCredentials.revoke(scope, credential)
    insert_message(thread_id: thread.id, body: "After access was revoked")
    send(view.pid, {:message_added, thread.id})

    assert_redirect(view, "/")
  end

  test "a pushed internal note never appears in the open customer request", %{conn: conn} do
    customer = insert_organization()
    thread = insert_thread(organization_id: customer.id)
    {:ok, view, _} = live(conn, "/portal/#{portal_token(customer)}/request/#{thread.id}")

    insert_message(
      thread_id: thread.id,
      body: "Staff-only confidential note",
      is_internal_note: true
    )

    send(view.pid, {:message_added, thread.id})

    refute render(view) =~ "Staff-only confidential note"
  end
end

defmodule CustyardWeb.Live.StaffAuthTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{Auth.Account, StaffAccount, Repo, Tenants}
  alias CustyardWeb.Live.StaffAuth

  test "session requires live account and exact claim" do
    staff = insert_staff_account(role: "admin")
    assert StaffAuth.session_staff(staff.id, staff.session_claim).id == staff.id
    refute StaffAuth.session_staff(staff.id, nil)
    refute StaffAuth.session_staff(staff.id, Account.generate_session_claim())
    Repo.delete!(staff)
    refute StaffAuth.session_staff(staff.id, staff.session_claim)
  end

  test "staff cannot authenticate on another tenant hostname", %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    foreign = insert_tenant()
    {:ok, _} = Tenants.add_host(foreign.id, "foreign.example.com")

    conn =
      %{conn | host: "foreign.example.com"}
      |> init_test_session(%{})
      |> put_staff_session(staff)

    assert redirected_to(get(conn, "/app")) == "/app/login"
  end

  test "admin pages reject agents", %{conn: conn} do
    staff = insert_staff_account(role: "agent")
    conn = conn |> init_test_session(%{}) |> put_staff_session(staff)
    assert {:error, {:redirect, %{to: "/app"}}} = live(conn, "/app/settings/email")
  end

  test "connected sockets recheck claim before processing an event", %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    conn = conn |> init_test_session(%{}) |> put_staff_session(staff)
    {:ok, view, _} = live(conn, "/app/settings/workspace")

    staff
    |> Ecto.Changeset.change(session_claim: Account.generate_session_claim())
    |> Repo.update!()

    render_submit(view, "invite", %{
      "staff" => %{"email" => "blocked@example.com", "role" => "agent"}
    })

    assert_redirect(view, "/app/login")
    refute Repo.get_by(StaffAccount, email: "blocked@example.com")
  end

  test "connected sockets recheck role before processing an event", %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    conn = conn |> init_test_session(%{}) |> put_staff_session(staff)
    {:ok, view, _} = live(conn, "/app/settings/workspace")
    staff |> StaffAccount.role_changeset(%{role: "agent"}) |> Repo.update!()

    render_submit(view, "invite", %{
      "staff" => %{"email" => "blocked@example.com", "role" => "agent"}
    })

    assert_redirect(view, "/app/login")
    refute Repo.get_by(StaffAccount, email: "blocked@example.com")
  end
end

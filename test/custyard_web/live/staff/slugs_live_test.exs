defmodule CustyardWeb.Staff.SlugsLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Custyard.{AuditEvent, Repo, Slug, Slugs}
  alias CustyardWeb.Staff.SlugsLive

  setup %{conn: conn} do
    # Default factory role is super_admin — the route's live_session requires it
    staff = insert_staff_account(role: "admin")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff.id)

    {:ok, conn: conn, staff: staff}
  end

  defp claim!(slug_text, email \\ "buyer@example.com") do
    conversation = insert_conversation(source: :public_intake)
    {:ok, slug, token} = Slugs.claim(slug_text, email, conversation)
    %{conversation: conversation, slug: slug, token: token}
  end

  defp release_audit_events do
    Repo.all(from e in AuditEvent, where: e.event_type == :slug_released)
  end

  describe "listing" do
    test "renders slug, status, email, expiry, and the conversation link", %{conn: conn} do
      %{slug: slug, conversation: conversation} = claim!("listed-claim")

      {:ok, _view, html} = live(conn, ~p"/app/settings/slugs")

      assert html =~ "staff-slugs-page"
      assert html =~ "listed-claim"
      assert html =~ "Provisional"
      assert html =~ "buyer@example.com"
      assert html =~ ~s(staff-slug-expiry-#{slug.id})
      assert html =~ ~s(href="/app/threads/#{conversation.id}")
    end

    test "renders confirmed and provisioned statuses", %{conn: conn} do
      %{slug: slug, token: token} = claim!("confirmed-claim")
      {:ok, _} = Slugs.confirm(token, slug.tenant_id)

      org = insert_organization()

      insert_slug(
        slug: "provisioned-claim",
        status: :provisioned,
        organization_id: org.id,
        confirmation_token_hash: nil,
        expires_at: nil
      )

      {:ok, _view, html} = live(conn, ~p"/app/settings/slugs")

      assert html =~ "Confirmed"
      assert html =~ "Provisioned"
    end

    test "renders empty state when the registry is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/settings/slugs")

      assert html =~ "staff-slugs-empty"
    end

    test "the nav entry renders next to intake sources", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/settings/slugs")

      assert html =~ "staff-nav-slugs"
      assert html =~ "staff-nav-intake-sources"
    end
  end

  describe "release" do
    test "releases a claimed slug, writes the audit event, and re-opens the name",
         %{conn: conn, staff: staff} do
      %{slug: slug, conversation: conversation} = claim!("give-back")

      {:ok, view, _html} = live(conn, ~p"/app/settings/slugs")

      view |> element("[data-testid=staff-slug-release-#{slug.id}]") |> render_click()

      assert render(view) =~ "released"
      refute Repo.get(Slug, slug.id)

      # The conversation survives — only the slug row dies.
      assert Repo.get(Custyard.Conversation, conversation.id)

      # Audit trail (append-only, :slug_released).
      assert [event] = release_audit_events()
      assert event.source == "staff"
      assert event.conversation_id == conversation.id
      assert event.payload["slug"] == "give-back"
      assert event.payload["status"] == "claimed"
      assert event.payload["email"] == "buyer@example.com"
      assert event.payload["staff_id"] == staff.id

      # Released means claimable again — by anyone.
      other = insert_conversation(source: :public_intake)
      assert {:ok, _slug, _token} = Slugs.claim("give-back", "next@example.com", other)
    end

    test "releases a confirmed slug", %{conn: conn} do
      %{slug: slug, token: token} = claim!("confirmed-release")
      {:ok, _} = Slugs.confirm(token, slug.tenant_id)

      {:ok, view, _html} = live(conn, ~p"/app/settings/slugs")

      view |> element("[data-testid=staff-slug-release-#{slug.id}]") |> render_click()

      refute Repo.get(Slug, slug.id)
      assert [event] = release_audit_events()
      assert event.payload["status"] == "confirmed"
    end

    test "refuses provisioned slugs — no release button, and the handler refuses forged events",
         %{conn: conn, staff: staff} do
      org = insert_organization()

      provisioned =
        insert_slug(
          slug: "provisioned-co",
          status: :provisioned,
          organization_id: org.id,
          confirmation_token_hash: nil,
          expires_at: nil
        )

      {:ok, view, html} = live(conn, ~p"/app/settings/slugs")

      # No release button renders for provisioned rows.
      refute html =~ "staff-slug-release-#{provisioned.id}"

      # A forged release event is refused by the context guard.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_staff: staff,
          current_scope:
            Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id)),
          current_tenant: Custyard.Tenants.get_tenant!(staff.tenant_id),
          slugs: []
        }
      }

      {:noreply, after_release} =
        SlugsLive.handle_event("release", %{"id" => to_string(provisioned.id)}, socket)

      assert after_release.assigns.flash["error"] =~ "Provisioned slugs"
      assert Repo.get(Slug, provisioned.id)
      assert release_audit_events() == []

      # Keep the mounted view referenced so it stays alive through the test.
      assert render(view) =~ "provisioned-co"
    end
  end

  describe "authorization (double gate)" do
    test "agent is redirected at route mount" do
      staff = insert_staff_account(role: "agent")

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(staff.id)

      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/app/settings/slugs")
    end

    test "non-super-admin cannot release via direct handle_event invocation" do
      # The route is mount-gated to super_admin; the double-gate branch in
      # the mutating handle_event is exercised by direct invocation, per
      # the settings_live_test precedent.
      staff = insert_staff_account(role: "agent")
      %{slug: slug} = claim!("guarded-slug")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_staff: staff,
          current_scope:
            Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id)),
          current_tenant: Custyard.Tenants.get_tenant!(staff.tenant_id),
          slugs: []
        }
      }

      {:noreply, after_release} =
        SlugsLive.handle_event("release", %{"id" => to_string(slug.id)}, socket)

      assert after_release.assigns.flash["error"] ==
               "Only tenant administrators can release slugs"

      assert Repo.get(Slug, slug.id)
      assert release_audit_events() == []
    end
  end
end

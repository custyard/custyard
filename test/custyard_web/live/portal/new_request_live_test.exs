defmodule CustyardWeb.Portal.NewRequestLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{Thread, Message, Repo}
  alias Custyard.Email.SenderMatcher

  describe "mount" do
    test "renders new request form", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      assert html =~ "New Request"
      assert html =~ "Subject"
      assert html =~ "Urgency"
      assert html =~ "Description"
      assert html =~ "Submit Request"
    end

    test "shows urgency options", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      assert html =~ "Normal"
      assert html =~ "Elevated"
      assert html =~ "Urgent"
    end

    test "has cancel link back to request list", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      assert view |> element("a", "Cancel") |> has_element?()
    end
  end

  describe "form submission" do
    test "shared portal requests use a personal-email customer's default contact", %{conn: conn} do
      {:ok, org, contact} =
        SenderMatcher.match_within_tenant(
          "Alex <alex@icloud.com>",
          Process.get(:factory_tenant_id)
        )

      {:ok, view, _} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Billing question",
        "body" => "Please check my billing details",
        "urgency" => "normal"
      })
      |> render_submit()

      thread = Repo.one!(from t in Thread, where: t.organization_id == ^org.id)
      message = Repo.one!(from m in Message, where: m.thread_id == ^thread.id)
      assert thread.contact_id == contact.id
      assert thread.source == :portal
      assert message.sender_email == "alex@icloud.com"
      assert Custyard.Threads.reply_channel(thread) == {:contact, "alex@icloud.com"}
    end

    test "an explicit portal contact takes precedence over the customer default", %{conn: conn} do
      org = insert_organization()
      default = insert_contact(organization_id: org.id, email: "default@example.com")
      explicit = insert_contact(organization_id: org.id, email: "explicit@example.com")
      Repo.update!(Ecto.Changeset.change(org, default_contact_id: default.id))
      {:ok, _, token} = Custyard.PortalCredentials.issue(portal_scope(org), org.id, explicit.id)
      {:ok, view, _} = live(conn, ~p"/portal/#{token}/new")

      view
      |> form("form", %{
        "subject" => "Explicit request",
        "body" => "Please reply to this contact",
        "urgency" => "normal"
      })
      |> render_submit()

      thread = Repo.one!(from t in Thread, where: t.organization_id == ^org.id)
      message = Repo.one!(from m in Message, where: m.thread_id == ^thread.id)
      assert thread.contact_id == explicit.id
      assert message.sender_email == explicit.email
    end

    test "a shared business portal does not guess between contacts", %{conn: conn} do
      org = insert_organization()
      insert_contact(organization_id: org.id)
      insert_contact(organization_id: org.id)
      {:ok, view, _} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Shared request",
        "body" => "Please check these account details",
        "urgency" => "normal"
      })
      |> render_submit()

      thread = Repo.one!(from t in Thread, where: t.organization_id == ^org.id)
      assert is_nil(thread.contact_id)
      assert Custyard.Threads.reply_channel(thread) == :none
    end

    test "creates thread on submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Test Request Subject",
        "body" => "This is the request description",
        "urgency" => "normal"
      })
      |> render_submit()

      # Verify thread was created
      conv = Repo.one(from c in Thread, where: c.organization_id == ^org.id)
      assert conv.subject == "Test Request Subject"
      assert conv.state == :new
      assert conv.urgency == :normal
    end

    test "creates initial message on submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Test Subject",
        "body" => "This is the message body",
        "urgency" => "normal"
      })
      |> render_submit()

      # Verify message was created
      conv = Repo.one(from c in Thread, where: c.organization_id == ^org.id)
      msg = Repo.one(from m in Message, where: m.thread_id == ^conv.id)

      assert msg.body == "This is the message body"
      assert msg.source == :portal
      assert msg.is_internal_note == false
    end

    test "redirects to thread page after submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      {:error, {:live_redirect, %{to: redirect_path}}} =
        view
        |> form("form", %{
          "subject" => "Test Subject",
          "body" => "Test body",
          "urgency" => "normal"
        })
        |> render_submit()

      assert redirect_path =~ ~r"/portal/#{portal_token(org)}/request/\d+"
    end

    test "creates elevated urgency thread", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Elevated Request",
        "body" => "Need attention",
        "urgency" => "elevated"
      })
      |> render_submit()

      conv = Repo.one(from c in Thread, where: c.organization_id == ^org.id)
      assert conv.urgency == :elevated
    end

    test "creates urgent urgency thread", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Urgent Request",
        "body" => "Critical issue",
        "urgency" => "urgent"
      })
      |> render_submit()

      conv = Repo.one(from c in Thread, where: c.organization_id == ^org.id)
      assert conv.urgency == :urgent
    end

    test "calculates and caches score on submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}/new")

      view
      |> form("form", %{
        "subject" => "Test Subject",
        "body" => "Test body",
        "urgency" => "normal"
      })
      |> render_submit()

      conv = Repo.one(from c in Thread, where: c.organization_id == ^org.id)
      # New thread should have score calculated (new=30 + standard=10 + idle ~= 40-42)
      assert conv.cached_score >= 40
      assert conv.cached_score <= 45
    end
  end
end

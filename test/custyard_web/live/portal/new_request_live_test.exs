defmodule CustyardWeb.Portal.NewRequestLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{Conversation, Message, Repo}

  describe "mount" do
    test "renders new request form", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/new")

      assert html =~ "New Request"
      assert html =~ "Subject"
      assert html =~ "Urgency"
      assert html =~ "Description"
      assert html =~ "Submit Request"
    end

    test "shows urgency options", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/new")

      assert html =~ "Normal"
      assert html =~ "Elevated"
      assert html =~ "Urgent"
    end

    test "has cancel link back to request list", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      assert view |> element("a", "Cancel") |> has_element?()
    end
  end

  describe "form submission" do
    test "creates conversation on submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      view
      |> form("form", %{
        "subject" => "Test Request Subject",
        "body" => "This is the request description",
        "urgency" => "normal"
      })
      |> render_submit()

      # Verify conversation was created
      conv = Repo.one(from c in Conversation, where: c.organization_id == ^org.id)
      assert conv.subject == "Test Request Subject"
      assert conv.state == :new
      assert conv.urgency == :normal
    end

    test "creates initial message on submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      view
      |> form("form", %{
        "subject" => "Test Subject",
        "body" => "This is the message body",
        "urgency" => "normal"
      })
      |> render_submit()

      # Verify message was created
      conv = Repo.one(from c in Conversation, where: c.organization_id == ^org.id)
      msg = Repo.one(from m in Message, where: m.conversation_id == ^conv.id)

      assert msg.body == "This is the message body"
      assert msg.source == :portal
      assert msg.is_internal_note == false
    end

    test "redirects to conversation page after submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      {:error, {:live_redirect, %{to: redirect_path}}} =
        view
        |> form("form", %{
          "subject" => "Test Subject",
          "body" => "Test body",
          "urgency" => "normal"
        })
        |> render_submit()

      assert redirect_path =~ ~r"/p/#{org.token}/request/\d+"
    end

    test "creates elevated urgency conversation", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      view
      |> form("form", %{
        "subject" => "Elevated Request",
        "body" => "Need attention",
        "urgency" => "elevated"
      })
      |> render_submit()

      conv = Repo.one(from c in Conversation, where: c.organization_id == ^org.id)
      assert conv.urgency == :elevated
    end

    test "creates urgent urgency conversation", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      view
      |> form("form", %{
        "subject" => "Urgent Request",
        "body" => "Critical issue",
        "urgency" => "urgent"
      })
      |> render_submit()

      conv = Repo.one(from c in Conversation, where: c.organization_id == ^org.id)
      assert conv.urgency == :urgent
    end

    test "calculates and caches score on submit", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/new")

      view
      |> form("form", %{
        "subject" => "Test Subject",
        "body" => "Test body",
        "urgency" => "normal"
      })
      |> render_submit()

      conv = Repo.one(from c in Conversation, where: c.organization_id == ^org.id)
      # New conversation should have score calculated (new=30 + standard=10 + idle ~= 40-42)
      assert conv.cached_score >= 40
      assert conv.cached_score <= 45
    end
  end
end

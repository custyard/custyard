defmodule CustyardWeb.Operator.IntakeSourcesLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{IntakeSource, Repo}
  alias CustyardWeb.Operator.IntakeSourcesLive

  setup %{conn: conn} do
    # Default factory role is super_admin - the route's live_session requires it
    operator = insert_operator_account()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)

    {:ok, conn: conn, operator: operator}
  end

  describe "listing" do
    test "renders existing sources", %{conn: conn} do
      insert_intake_source(key: "landing-page", name: "Landing Page", mode: :active)

      insert_intake_source(
        key: "docs-footer",
        name: "Docs Footer",
        mode: :passive,
        enabled: false
      )

      {:ok, _view, html} = live(conn, ~p"/operator/intake-sources")

      assert html =~ "operator-intake-sources-page"
      assert html =~ "landing-page"
      assert html =~ "Landing Page"
      assert html =~ "docs-footer"
      assert html =~ "operator-intake-source-disabled-badge"
    end

    test "renders empty state when there are no sources", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/operator/intake-sources")

      assert html =~ "operator-intake-sources-empty"
    end
  end

  describe "create" do
    test "creates a source with a valid key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-sources-add-btn]") |> render_click()

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{
          "key" => "landing-page",
          "name" => "Landing Page",
          "mode" => "active",
          "headline" => "Need help?",
          "intro_copy" => "Tell us what is going on.",
          "enabled" => "true"
        }
      })
      |> render_submit()

      assert render(view) =~ "Intake source created successfully"

      source = Repo.get_by!(IntakeSource, key: "landing-page")
      assert source.name == "Landing Page"
      assert source.mode == :active
      assert source.headline == "Need help?"
      assert source.intro_copy == "Tell us what is going on."
      assert source.enabled == true
      assert source.questions == []
    end

    test "rejects an invalid key with a changeset error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-sources-add-btn]") |> render_click()

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{"key" => "Bad Key!", "name" => "Bad"}
      })
      |> render_submit()

      assert render(view) =~ "has invalid format"
      refute Repo.get_by(IntakeSource, name: "Bad")
    end

    test "surfaces a key uniqueness violation as a changeset error, not a crash", %{conn: conn} do
      insert_intake_source(key: "dupe")

      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-sources-add-btn]") |> render_click()

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{"key" => "dupe", "name" => "Duplicate"}
      })
      |> render_submit()

      assert render(view) =~ "has already been taken"
      assert Repo.aggregate(IntakeSource, :count) == 1
    end
  end

  describe "edit" do
    test "the key is not editable in the form and survives an update", %{conn: conn} do
      source = insert_intake_source(key: "locked-key", name: "Before")

      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-source-edit-#{source.id}]") |> render_click()

      html = render(view)
      assert html =~ "operator-intake-source-key-readonly"
      assert html =~ "cannot be changed"
      refute html =~ ~s(name="intake_source[key]")

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{"name" => "After"}
      })
      |> render_submit()

      assert render(view) =~ "Intake source updated successfully"

      reloaded = Repo.get!(IntakeSource, source.id)
      assert reloaded.key == "locked-key"
      assert reloaded.name == "After"
    end

    test "a forged key in the save params is stripped before the changeset", %{operator: operator} do
      # The edit form has no key input, so a changed key can only arrive as a
      # forged event payload - exercised by invoking the handler directly.
      source = insert_intake_source(key: "original-key", name: "Original")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_operator: operator,
          editing_source: source,
          form_params: %{},
          questions: [],
          sources: []
        }
      }

      {:noreply, _socket} =
        IntakeSourcesLive.handle_event(
          "save",
          %{"intake_source" => %{"key" => "forged-key", "name" => "Renamed"}},
          socket
        )

      reloaded = Repo.get!(IntakeSource, source.id)
      assert reloaded.key == "original-key"
      assert reloaded.name == "Renamed"
    end
  end

  describe "questions" do
    test "rows can be added, filled in, and persisted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-sources-add-btn]") |> render_click()
      view |> element("[data-testid=operator-intake-source-add-question]") |> render_click()
      view |> element("[data-testid=operator-intake-source-add-question]") |> render_click()

      assert has_element?(view, "[data-testid=operator-intake-source-question-row-1]")

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{
          "key" => "faq-page",
          "name" => "FAQ",
          "mode" => "passive",
          "questions" => %{
            "0" => %{"question" => "What is this?", "answer" => "A support tool."},
            "1" => %{"question" => "How much?", "answer" => "Free."}
          }
        }
      })
      |> render_submit()

      source = Repo.get_by!(IntakeSource, key: "faq-page")

      assert source.questions == [
               %{"question" => "What is this?", "answer" => "A support tool."},
               %{"question" => "How much?", "answer" => "Free."}
             ]
    end

    test "rows can be removed on edit", %{conn: conn} do
      source =
        insert_intake_source(
          key: "faq-trim",
          questions: [
            %{"question" => "First?", "answer" => "Yes."},
            %{"question" => "Second?", "answer" => "Also yes."}
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-source-edit-#{source.id}]") |> render_click()

      assert has_element?(view, "[data-testid=operator-intake-source-question-row-1]")

      view
      |> element("[data-testid=operator-intake-source-remove-question-0]")
      |> render_click()

      refute has_element?(view, "[data-testid=operator-intake-source-question-row-1]")

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{
          "name" => source.name,
          "questions" => %{"0" => %{"question" => "Second?", "answer" => "Also yes."}}
        }
      })
      |> render_submit()

      reloaded = Repo.get!(IntakeSource, source.id)
      assert reloaded.questions == [%{"question" => "Second?", "answer" => "Also yes."}]
    end

    test "the add button stops at the validated cap", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-sources-add-btn]") |> render_click()

      for _ <- 1..IntakeSource.max_questions() do
        view |> element("[data-testid=operator-intake-source-add-question]") |> render_click()
      end

      html = render(view)
      last_index = IntakeSource.max_questions() - 1

      assert html =~ "operator-intake-source-questions-cap"
      assert html =~ "operator-intake-source-question-row-#{last_index}"
      refute html =~ "operator-intake-source-question-row-#{last_index + 1}"
      refute has_element?(view, "[data-testid=operator-intake-source-add-question]")
    end

    test "blank rows are dropped on save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view |> element("[data-testid=operator-intake-sources-add-btn]") |> render_click()
      view |> element("[data-testid=operator-intake-source-add-question]") |> render_click()

      view
      |> form("[data-testid=operator-intake-source-form]", %{
        "intake_source" => %{
          "key" => "no-blanks",
          "name" => "No Blanks",
          "questions" => %{"0" => %{"question" => "", "answer" => ""}}
        }
      })
      |> render_submit()

      assert Repo.get_by!(IntakeSource, key: "no-blanks").questions == []
    end
  end

  describe "enabled toggle" do
    test "flips the enabled flag from the list", %{conn: conn} do
      source = insert_intake_source(enabled: true)

      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view
      |> element("[data-testid=operator-intake-source-toggle-#{source.id}]")
      |> render_click()

      assert Repo.get!(IntakeSource, source.id).enabled == false
      assert render(view) =~ "operator-intake-source-disabled-badge"

      view
      |> element("[data-testid=operator-intake-source-toggle-#{source.id}]")
      |> render_click()

      assert Repo.get!(IntakeSource, source.id).enabled == true
    end
  end

  describe "delete" do
    test "removes the source", %{conn: conn} do
      source = insert_intake_source(key: "doomed")

      {:ok, view, _html} = live(conn, ~p"/operator/intake-sources")

      view
      |> element("[data-testid=operator-intake-source-delete-#{source.id}]")
      |> render_click()

      assert render(view) =~ "Intake source deleted"
      refute Repo.get(IntakeSource, source.id)
    end
  end

  describe "authorization" do
    test "admin is redirected at route mount" do
      operator = insert_operator_account(role: "admin")

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, operator.id)

      assert {:error, {:redirect, %{to: "/operator"}}} =
               live(conn, ~p"/operator/intake-sources")
    end

    test "agent is redirected at route mount" do
      operator = insert_operator_account(role: "agent")

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, operator.id)

      assert {:error, {:redirect, %{to: "/operator"}}} =
               live(conn, ~p"/operator/intake-sources")
    end

    test "non-super-admin cannot mutate via direct handle_event invocation" do
      # The route is mount-gated to super_admin; the double-gate branch in
      # each mutating handle_event is exercised by direct invocation, per the
      # settings_live_test precedent.
      operator = insert_operator_account(role: "admin")
      source = insert_intake_source(key: "guarded", enabled: true)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_operator: operator}
      }

      {:noreply, after_save} =
        IntakeSourcesLive.handle_event(
          "save",
          %{"intake_source" => %{"key" => "sneaky", "name" => "Sneaky"}},
          socket
        )

      assert after_save.assigns.flash["error"] ==
               "Only super admins can modify intake sources"

      refute Repo.get_by(IntakeSource, key: "sneaky")

      {:noreply, after_delete} =
        IntakeSourcesLive.handle_event("delete", %{"id" => to_string(source.id)}, socket)

      assert after_delete.assigns.flash["error"] ==
               "Only super admins can modify intake sources"

      assert Repo.get(IntakeSource, source.id)

      {:noreply, after_toggle} =
        IntakeSourcesLive.handle_event("toggle_enabled", %{"id" => to_string(source.id)}, socket)

      assert after_toggle.assigns.flash["error"] ==
               "Only super admins can modify intake sources"

      assert Repo.get!(IntakeSource, source.id).enabled == true
    end
  end
end

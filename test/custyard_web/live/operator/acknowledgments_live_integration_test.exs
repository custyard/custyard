defmodule CustyardWeb.Operator.AcknowledgmentsLiveIntegrationTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.AcknowledgmentsBroker
  import Custyard.Factory
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Custyard.{AuditEvent, Repo}
  alias Custyard.Acknowledgments.Topology

  @moduletag :rabbitmq
  @moduletag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

  setup %{conn: conn} do
    ctx = setup_topology()
    operator = insert_operator_account()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(operator)

    Map.merge(ctx, %{conn: conn, operator: operator})
  end

  defp body(submission_id), do: Jason.encode!(evidence(%{"submission_id" => submission_id}))

  defp replay_audits,
    do: Repo.all(from e in AuditEvent, where: e.event_type == :acknowledgment_replayed)

  test "queue counts load after the connected mount", ctx do
    put_failure(ctx, body("one"))
    await_failures(ctx, 1)

    {:ok, view, _html} = live(ctx.conn, ~p"/operator/acknowledgments")
    render_async(view)

    assert view |> element("[data-testid=acknowledgments-queue-work]") |> render() =~
             ctx.config[:queue]

    failed = view |> element("[data-testid=acknowledgments-queue-failed]") |> render()
    assert failed =~ Topology.failure(ctx.config)
    assert failed =~ ~r/>\s*1\s*</
    assert has_element?(view, "[data-testid=acknowledgments-queue-retry-1]")
  end

  test "inspect shows sanitized fields only; replay is confirmed and audited", ctx do
    put_failure(ctx, body("ui-1"))
    put_failure(ctx, body("ui-2"))
    await_failures(ctx, 2)

    {:ok, view, _html} = live(ctx.conn, ~p"/operator/acknowledgments")
    render_async(view)

    view |> element("[data-testid=acknowledgments-inspect]") |> render_click()
    html = render_async(view)

    summary = view |> element("[data-testid=acknowledgments-summary]") |> render()
    assert summary =~ "ui-1"
    assert summary =~ "ots.integration"
    assert summary =~ "unmapped_organization"
    assert summary =~ ~r/>\s*4\s*</

    # Neither the evidence nor the URL reaches the page or the socket.
    statement = evidence()["statement_text"]
    assigns = inspect(:sys.get_state(view.pid).socket.assigns, limit: :infinity)
    refute html =~ "Versioned Colonel statement"
    refute assigns =~ "Versioned Colonel statement"
    refute assigns =~ String.replace(statement, "\n", "\\n")
    refute assigns =~ URI.parse(ctx.config[:url]).userinfo

    view |> element("[data-testid=acknowledgments-replay]") |> render_click()
    assert has_element?(view, "[data-testid=acknowledgments-replay-confirmation]")
    await_failures(ctx, 2)

    view |> element("[data-testid=acknowledgments-confirm-replay]") |> render_click()
    render_async(view)

    assert view |> element("[data-testid=acknowledgments-replay-result]") |> render() =~
             "Replayed to the work queue"

    await_failures(ctx, 1)
    assert {:ok, replayed, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
    assert replayed == body("ui-1")

    assert [%{source: "operator", payload: payload}] = replay_audits()
    assert payload["operator_id"] == ctx.operator.id
    assert payload["operator_email"] == ctx.operator.email
    assert payload["submission_id"] == "ui-1"
    assert payload["outcome"] == "replayed"
  end

  test "a head that changed after inspect is not replayed", ctx do
    put_failure(ctx, body("inspected"))
    put_failure(ctx, body("next"))
    await_failures(ctx, 2)

    {:ok, view, _html} = live(ctx.conn, ~p"/operator/acknowledgments")
    render_async(view)
    view |> element("[data-testid=acknowledgments-inspect]") |> render_click()
    render_async(view)
    await_failures(ctx, 2)

    # Someone else replays the inspected message from a terminal meanwhile.
    {inspected, meta} = get_failed(ctx)
    assert inspected == body("inspected")
    :ok = AMQP.Basic.ack(ctx.channel, meta.delivery_tag)

    view |> element("[data-testid=acknowledgments-replay]") |> render_click()
    view |> element("[data-testid=acknowledgments-confirm-replay]") |> render_click()
    render_async(view)

    assert view |> element("[data-testid=acknowledgments-replay-result]") |> render() =~
             "changed; inspect again"

    await_failures(ctx, 1)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
    assert [%{payload: %{"outcome" => "changed", "submission_id" => "next"}}] = replay_audits()
  end

  test "an unreadable message offers no replay", ctx do
    put_failure(ctx, "{not json")
    await_failures(ctx, 1)

    {:ok, view, _html} = live(ctx.conn, ~p"/operator/acknowledgments")
    render_async(view)
    view |> element("[data-testid=acknowledgments-inspect]") |> render_click()
    render_async(view)

    assert has_element?(view, "[data-testid=acknowledgments-unreadable]")
    refute has_element?(view, "[data-testid=acknowledgments-replay]")

    # A crafted event cannot replay it either.
    render_click(view, "confirm_replay", %{})
    render_click(view, "replay", %{})
    render_async(view)
    await_failures(ctx, 1)
    assert replay_audits() == []
  end

  test "closing the page mid-replay still completes and audits the replay", ctx do
    put_failure(ctx, body("confirmed"))
    await_failures(ctx, 1)
    Process.flag(:trap_exit, true)

    {:ok, view, _html} = live(ctx.conn, ~p"/operator/acknowledgments")
    render_async(view)
    view |> element("[data-testid=acknowledgments-inspect]") |> render_click()
    render_async(view)
    view |> element("[data-testid=acknowledgments-replay]") |> render_click()
    view |> element("[data-testid=acknowledgments-confirm-replay]") |> render_click()

    # Once the replay holds (or has removed) the message, close the page.
    eventually(fn -> ready_count(ctx, Topology.failure(ctx.config)) == 0 end)
    Process.exit(view.pid, :kill)

    assert %{payload: %{"outcome" => "replayed", "submission_id" => "confirmed"}} =
             eventually(fn -> List.first(replay_audits()) end)

    await_failures(ctx, 0)
    assert {:ok, replayed, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
    assert replayed == body("confirmed")
  end

  test "closing the page mid-inspect returns the message to its queue", ctx do
    put_failure(ctx, body("closing"))
    await_failures(ctx, 1)
    Process.flag(:trap_exit, true)

    {:ok, view, _html} = live(ctx.conn, ~p"/operator/acknowledgments")
    render_async(view)
    view |> element("[data-testid=acknowledgments-inspect]") |> render_click()
    Process.exit(view.pid, :kill)

    # Whether the task was mid-operation or done, nothing stays held.
    await_failures(ctx, 1)
    {failed, _meta} = get_failed(ctx)
    assert failed == body("closing")
  end
end

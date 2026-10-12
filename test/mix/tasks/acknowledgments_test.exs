defmodule Mix.Tasks.AcknowledgmentsTest do
  # Replaces the application's acknowledgment configuration and Mix task state.
  use Custyard.DataCase, async: false

  import ExUnit.CaptureIO
  import Custyard.AcknowledgmentsBroker

  alias Custyard.Acknowledgments.Consumer

  # The tasks run with the provisioning credential from a workstation. Had
  # one called app.start, a shell with ACKNOWLEDGMENTS_ENABLED=true (or a prod
  # MIX_ENV) would start the consumer against production with that
  # credential, plus the endpoint, pollers and mail queue.
  defp run_task(task, args) do
    Mix.Task.reenable("app.start")

    {result, output} =
      with_io(fn ->
        try do
          task.run(args)
        catch
          :exit, {:shutdown, status} -> {:exit, status}
        end
      end)

    # app.start reports :noop only once it has run since the reenable above.
    refute Mix.Task.run("app.start") == :noop, "#{inspect(task)} ran app.start"
    {result, output}
  end

  test "no task starts the application, whatever the configuration says" do
    previous = Application.get_env(:custyard, :acknowledgments)
    on_exit(fn -> Application.put_env(:custyard, :acknowledgments, previous) end)

    # Enabled and complete, but unreachable: the work fails fast at the broker.
    Application.put_env(:custyard, :acknowledgments,
      enabled: true,
      url: "amqp://custyard:mix-task-pw@127.0.0.1:1/ots",
      source: "ots.mix.check",
      queue: "custyard.acknowledgments"
    )

    org = Custyard.Factory.insert_organization()

    for {task, args} <- [
          {Mix.Tasks.Acknowledgments.Status, []},
          {Mix.Tasks.Acknowledgments.Provision, []},
          {Mix.Tasks.Acknowledgments.Inspect, []},
          {Mix.Tasks.Acknowledgments.Replay, []},
          {Mix.Tasks.Acknowledgments.Bind, ["ots.mix.check", "org-1", "#{org.id}"]}
        ] do
      capture_io(:stderr, fn -> run_task(task, args) end)
      refute Process.whereis(Consumer), "#{inspect(task)} started the consumer"
    end
  end

  test "bind runs through the release path and audits as mix" do
    org = Custyard.Factory.insert_organization()

    {:ok, output} =
      run_task(Mix.Tasks.Acknowledgments.Bind, ["ots.mix.check", "org-mix", "#{org.id}"])

    assert output =~ "Bound ots.mix.check org-mix to organization #{org.id}"

    assert [%{source: "mix", payload: %{"actor" => "mix"}}] =
             Repo.all(
               from e in Custyard.AuditEvent,
                 where: e.event_type == :acknowledgment_binding_created
             )
  end

  test "a failing command exits with its status" do
    {{result, _output}, errors} =
      with_io(:stderr, fn -> run_task(Mix.Tasks.Acknowledgments.Bind, ["only-one-arg"]) end)

    assert result == {:exit, 1}
    assert errors =~ "Usage: bin/acknowledgments COMMAND"
  end

  describe "against the broker" do
    @describetag :rabbitmq
    @describetag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

    setup do
      ctx = setup_topology(source: "ots.integration")
      config = Application.get_env(:custyard, :acknowledgments)
      Application.put_env(:custyard, :acknowledgments, Keyword.put(config, :enabled, true))
      ctx
    end

    test "status reports the queues without a consumer subscribing", ctx do
      {:ok, output} = run_task(Mix.Tasks.Acknowledgments.Status, [])

      assert output =~ "#{ctx.config[:queue]}: 0 ready, 0 consumers"
      refute Process.whereis(Consumer)
    end

    test "replay audits as mix", ctx do
      put_failure(ctx, Jason.encode!(evidence()))
      await_failures(ctx, 1)

      {:ok, output} = run_task(Mix.Tasks.Acknowledgments.Replay, ["stable"])
      assert output =~ "Replayed the oldest failed message"

      assert [
               %{source: "mix", payload: %{"outcome" => "started"}},
               %{source: "mix", payload: %{"outcome" => "replayed"}}
             ] =
               Repo.all(
                 from e in Custyard.AuditEvent,
                   where: e.event_type == :acknowledgment_replayed,
                   order_by: e.id
               )
    end
  end
end

defmodule Custyard.Boot.FirstRunTest do
  # Writes Custyard.Boot.State, shares the sandbox with the FirstRun process
  # and redirects Swoosh's test adapter: sequential.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog

  alias Custyard.{AuditEvent, OperatorAccount}
  alias Custyard.Boot.{Env, FirstRun, State}

  @minimal %{
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "custyard.example.com",
    "MAIL_ADAPTER" => "lettermint",
    "LETTERMINT_PROJECT_TOKEN" => "lm_project_token",
    "OPERATOR_EMAIL" => "Ops@Example.com"
  }

  @schema %{total: 41, applied: 0, skipped: false, operators: 0}

  defmodule UnavailableRepo do
    def config, do: raise("MIGRATE_FAILURE_PRIVATE_CANARY")
  end

  setup do
    State.reset()
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      State.reset()
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  defp env(overrides \\ %{}) do
    Env.read(Map.merge(@minimal, overrides), config_env: :prod)
  end

  # Starts FirstRun and waits for handle_continue to finish.
  defp run(env, opts \\ []) do
    pid =
      start_supervised!(
        Supervisor.child_spec(
          {FirstRun, [env: env, schema: @schema, recheck_every_ms: 20, name: nil] ++ opts},
          id: {FirstRun, System.unique_integer()}
        )
      )

    :sys.get_state(pid)
    pid
  end

  defp step(key), do: Enum.find(State.get().first_run.steps, &(&1.key == key))

  defp wait_for(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_for(fun, attempts - 1)
    end
  end

  describe "operator bootstrap and welcome mail" do
    test "creates the operator once, mails it without a login link, and is ready" do
      run(env())

      operator = Repo.get_by!(OperatorAccount, email: "ops@example.com")
      assert operator.role == "super_admin"
      assert [%{source: "boot", payload: %{"via" => "boot"}}] = Repo.all(AuditEvent)

      assert_receive {:email, email}
      assert email.to == [{"", "ops@example.com"}]
      assert email.from == {"Custyard", "noreply@custyard.example.com"}
      assert email.subject == "Your Custyard is ready"
      assert email.html_body == nil
      assert email.text_body =~ "https://custyard.example.com is set up"
      assert email.text_body =~ "https://custyard.example.com/operator/login"
      assert email.text_body =~ "OPERATOR_EMAIL can be removed"
      refute email.text_body =~ "/operator/login/"
      refute email.text_body =~ "token"

      assert step(:schema) == %{key: :schema, status: :ok, detail: "41 migrations applied"}

      assert step(:operator) == %{
               key: :operator,
               status: :ok,
               detail: "ops@example.com (super_admin), from OPERATOR_EMAIL"
             }

      assert step(:mail) == %{key: :mail, status: :ok, detail: "accepted by lettermint"}
      assert step(:sign_in) == %{key: :sign_in, status: :ok, detail: "an operator can sign in"}

      state = State.get()
      assert state.mode == :ready
      assert state.first_run.operator_email == "ops@example.com"
      assert %DateTime{} = state.first_run.completed_at
      assert %{adapter: :lettermint, status: :ok} = state.last_mail
    end

    test "an existing operator is left alone and gets no mail" do
      org = insert_organization()

      existing =
        insert_operator_account(email: "ops@example.com", role: "admin", organization_id: org.id)

      before = Repo.get!(OperatorAccount, existing.id)

      run(env())

      refute_received {:email, _}
      assert Repo.get!(OperatorAccount, existing.id) == before
      assert Repo.aggregate(OperatorAccount, :count) == 1
      assert step(:operator).detail == "exists, not modified"
      assert step(:mail) == %{key: :mail, status: :skipped, detail: "no new operator"}
      assert State.get().last_mail == nil
      # An admin whose organization exists can log in.
      assert State.mode() == :ready
    end

    test "records the provider's status and message when the mail is rejected" do
      reason =
        {422,
         %{
           "code" => "sender_not_verified",
           "message" => "sender address noreply@custyard.example.com is not verified"
         }}

      log =
        capture_log(fn ->
          run(env(), deliver: fn _email -> {:error, reason} end)
        end)

      assert step(:mail) == %{
               key: :mail,
               status: :failed,
               detail:
                 "lettermint rejected the message (422: sender address [redacted] is not verified)"
             }

      assert %{adapter: :lettermint, status: :error, detail: "lettermint rejected" <> _} =
               State.get().last_mail

      assert log =~ "boot_welcome_mail_failed"
      assert log =~ "provider_status=422"
      assert log =~ "provider_code=sender_not_verified"
      refute log =~ "noreply@"
      # The operator exists regardless, so the instance is usable once mail is fixed.
      assert State.mode() == :ready
    end

    test "a transport failure and a raising adapter are recorded too" do
      capture_log(fn -> run(env(), deliver: fn _email -> {:error, :econnrefused} end) end)

      assert step(:mail) == %{
               key: :mail,
               status: :failed,
               detail: "lettermint rejected the message (econnrefused)"
             }

      State.reset()
      Repo.delete_all(OperatorAccount)
      Repo.delete_all(AuditEvent)

      capture_log(fn ->
        run(env(), deliver: fn _email -> raise ArgumentError, "boom at https://api.example" end)
      end)

      assert step(:mail) == %{
               key: :mail,
               status: :failed,
               detail: "lettermint rejected the message (boom at [redacted])"
             }
    end

    test "MAIL_ADAPTER=local skips the mail" do
      run(env(%{"MAIL_ADAPTER" => "local"}))
      refute_received {:email, _}

      assert step(:mail) == %{
               key: :mail,
               status: :skipped,
               detail: "MAIL_ADAPTER=local discards mail"
             }

      assert State.mode() == :ready
    end

    test "the placeholder address fails validation and is recorded" do
      run(env(%{"OPERATOR_EMAIL" => "admin@custyard.local"}))

      assert %{status: :failed, detail: detail} = step(:operator)
      assert detail =~ "non-routable placeholder"
      assert step(:mail).status == :skipped
      assert Repo.aggregate(OperatorAccount, :count) == 0
      assert State.mode() == :first_run
    end
  end

  describe "first-run mode" do
    test "stays first_run without OPERATOR_EMAIL and flips to ready when an operator appears" do
      run(env(%{"OPERATOR_EMAIL" => ""}))

      assert step(:operator) == %{
               key: :operator,
               status: :skipped,
               detail: "OPERATOR_EMAIL is not set"
             }

      assert step(:mail) == %{key: :mail, status: :skipped, detail: "no new operator"}
      assert step(:sign_in).status == :pending
      assert State.mode() == :first_run
      assert State.get().first_run.completed_at == nil

      # The placeholder cannot log in, so it does not end first run.
      insert_operator_account(email: "admin@custyard.local")
      Process.sleep(60)
      assert State.mode() == :first_run

      insert_operator_account(email: "later@example.com")
      wait_for(fn -> State.mode() == :ready end)
      assert step(:sign_in) == %{key: :sign_in, status: :ok, detail: "an operator can sign in"}
      assert %DateTime{} = State.get().first_run.completed_at
    end

    test "a schema that was skipped says so" do
      pid =
        start_supervised!(
          {FirstRun,
           env: env(),
           schema: %{@schema | skipped: true, applied: 0},
           recheck_every_ms: 20,
           name: nil}
        )

      :sys.get_state(pid)

      assert step(:schema).detail ==
               "41 migrations applied, pending ones skipped (SKIP_MIGRATIONS)"
    end
  end

  describe "migrate/2" do
    test "runs on the current repo and counts" do
      assert {:ok, %{total: total, applied: 0, skipped: false, operators: 0}} =
               FirstRun.migrate(Repo, start_repo: false)

      assert total > 0
      assert total == length(Ecto.Migrator.migrated_versions(Repo))

      insert_operator_account(email: "ops@example.com")

      assert {:ok, %{skipped: true, operators: 1}} =
               FirstRun.migrate(Repo, start_repo: false, skip: true)
    end

    test "a repo that cannot start is an error without the exception text" do
      assert {:error, detail, %RuntimeError{}} = FirstRun.migrate(UnavailableRepo)
      assert detail == "the database could not be opened for migrations"
      refute detail =~ "CANARY"
    end

    test "schema_detail/1 wording" do
      assert FirstRun.schema_detail(%{total: 41, applied: 0, skipped: false}) ==
               "41 migrations applied"

      assert FirstRun.schema_detail(%{total: 41, applied: 3, skipped: false}) ==
               "41 migrations applied, 3 new this boot"
    end
  end

  describe "provider_error/1" do
    test "extracts status and a bounded message from each Swoosh error shape" do
      assert FirstRun.provider_error({422, %{"message" => "bad sender"}}) == {422, "bad sender"}

      assert FirstRun.provider_error({401, %{"error" => %{"message" => "token for x@y.z"}}}) ==
               {401, "token for [redacted]"}

      assert FirstRun.provider_error({500, "<html>oops</html>"}) == {500, "<html>oops</html>"}
      assert FirstRun.provider_error(:smtp_down) == {nil, "smtp_down"}

      assert FirstRun.provider_error(%RuntimeError{message: "x"}) == {nil, "x"}
      assert {nil, "{:retries_exceeded, " <> _} = FirstRun.provider_error({:retries_exceeded, :x})
    end
  end
end

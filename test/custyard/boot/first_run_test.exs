defmodule Custyard.Boot.FirstRunTest do
  # Writes Custyard.Boot.State, shares the sandbox with the FirstRun process
  # and redirects Swoosh's test adapter: sequential.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog

  alias Custyard.{AuditEvent, InstanceAdmin, InstanceAdmins}
  alias Custyard.Boot.{Env, FirstRun, State}

  @minimal %{
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "custyard.example.com",
    "MAIL_ADAPTER" => "lettermint",
    "LETTERMINT_PROJECT_TOKEN" => "lm_project_token",
    "INSTANCE_ADMIN_EMAIL" => "Ops@Example.com"
  }

  @schema %{total: 41, applied: 0, skipped: false, instance_admins: 0}

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

  defp insert_instance_admin(email) do
    {:created, admin} = InstanceAdmins.create_admin(email)
    admin
  end

  defp step(key), do: Enum.find(State.get().first_run.steps, &(&1.key == key))

  defp wait_for(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_for(fun, attempts - 1)
    end
  end

  describe "instance administrator bootstrap and welcome mail" do
    test "creates the administrator once, mails it without a login link, and is ready" do
      run(env())

      admin = Repo.get_by!(InstanceAdmin, email: "ops@example.com")

      assert [
               %{
                 event_type: :instance_admin_created,
                 source: "instance_admin",
                 payload: %{"instance_admin_id" => admin_id}
               }
             ] = Repo.all(AuditEvent)

      assert admin_id == admin.id

      assert_receive {:email, email}
      assert email.to == [{"", "ops@example.com"}]
      assert email.from == {"Custyard", "noreply@custyard.example.com"}
      assert email.subject == "Your Custyard is ready"
      assert email.html_body == nil
      assert email.text_body =~ "https://custyard.example.com is set up"
      assert email.text_body =~ "https://custyard.example.com/admin/login"
      assert email.text_body =~ "INSTANCE_ADMIN_EMAIL can be removed"
      refute email.text_body =~ "/admin/login/"
      refute email.text_body =~ "token"

      assert step(:schema) == %{key: :schema, status: :ok, detail: "41 migrations applied"}

      assert step(:instance_admin) == %{
               key: :instance_admin,
               status: :ok,
               detail: "ops@example.com, from INSTANCE_ADMIN_EMAIL"
             }

      assert step(:mail) == %{key: :mail, status: :ok, detail: "accepted by lettermint"}

      assert step(:sign_in) == %{
               key: :sign_in,
               status: :ok,
               detail: "an instance administrator can sign in"
             }

      state = State.get()
      assert state.mode == :ready
      assert state.first_run.instance_admin_email == "ops@example.com"
      assert %DateTime{} = state.first_run.completed_at
      assert %{adapter: :lettermint, status: :ok} = state.last_mail
    end

    test "an existing administrator is left alone and gets no mail" do
      existing = insert_instance_admin("ops@example.com")
      before = Repo.get!(InstanceAdmin, existing.id)

      run(env())

      refute_received {:email, _}
      assert Repo.get!(InstanceAdmin, existing.id) == before
      assert Repo.aggregate(InstanceAdmin, :count) == 1
      assert step(:instance_admin).detail == "exists, not modified"
      assert step(:mail) == %{key: :mail, status: :skipped, detail: "no new administrator"}
      assert State.get().last_mail == nil
      # An existing administrator can sign in.
      assert State.mode() == :ready
      # Nothing was set up this boot, so "/" stays the landing page.
      assert State.get().first_run.completed_at == nil
      assert step(:sign_in).status == :ok
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
      # The administrator exists regardless, so the instance is usable once mail is fixed.
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
      Repo.delete_all(InstanceAdmin)
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

    test "an address the account rejects is recorded without the value" do
      configured = env()
      settings = %{configured.settings | instance_admin_email: "not-an-address"}
      run(%{configured | settings: settings})

      assert %{status: :failed, detail: detail} = step(:instance_admin)
      assert detail == "INSTANCE_ADMIN_EMAIL is not a usable address"
      refute detail =~ "not-an-address"
      assert step(:mail).status == :skipped
      assert Repo.aggregate(InstanceAdmin, :count) == 0
      assert State.mode() == :first_run
    end
  end

  describe "first-run mode" do
    test "leaves :starting for :ready when administrators exist, before the bootstrap step" do
      insert_instance_admin("ops@example.com")
      State.put(%State{mode: :starting})

      run(env())

      assert State.mode() == :ready
      assert step(:instance_admin).detail == "exists, not modified"
      assert State.get().first_run.completed_at == nil
    end

    test "leaves :starting for :first_run on an empty database and completes it" do
      State.put(%State{mode: :starting})

      run(env())

      assert State.mode() == :ready
      assert step(:instance_admin).status == :ok
      assert %DateTime{} = State.get().first_run.completed_at
    end

    test "a failed administrator count stays in :starting and decides on the recheck" do
      insert_instance_admin("ops@example.com")
      State.put(%State{mode: :starting})
      {:ok, database} = Agent.start_link(fn -> :down end)

      count = fn ->
        if Agent.get(database, & &1) == :down,
          do: raise(RuntimeError, "COUNT_FAILURE_PRIVATE_CANARY"),
          else: InstanceAdmins.count()
      end

      log =
        capture_log(fn ->
          run(env(%{"INSTANCE_ADMIN_EMAIL" => ""}), count: count)
          Process.sleep(60)
        end)

      # An unknown count is not "no administrators": the mode is undecided.
      assert State.mode() == :starting
      assert log =~ "boot_instance_admin_count_failed"
      refute log =~ "COUNT_FAILURE_PRIVATE_CANARY"

      Agent.update(database, fn _ -> :up end)
      wait_for(fn -> State.mode() == :ready end)
      # The administrators were there all along, so this was not a first run.
      assert State.get().first_run.completed_at == nil
    end

    test "stays first_run without INSTANCE_ADMIN_EMAIL and flips to ready when an administrator appears" do
      run(env(%{"INSTANCE_ADMIN_EMAIL" => ""}))

      assert step(:instance_admin) == %{
               key: :instance_admin,
               status: :skipped,
               detail: "INSTANCE_ADMIN_EMAIL is not set"
             }

      assert step(:mail) == %{key: :mail, status: :skipped, detail: "no new administrator"}
      assert step(:sign_in).status == :pending
      assert State.mode() == :first_run
      assert State.get().first_run.completed_at == nil

      insert_instance_admin("later@example.com")
      wait_for(fn -> State.mode() == :ready end)

      assert step(:sign_in) == %{
               key: :sign_in,
               status: :ok,
               detail: "an instance administrator can sign in"
             }

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
      assert {:ok, %{total: total, applied: 0, skipped: false, instance_admins: 0}} =
               FirstRun.migrate(Repo, start_repo: false)

      assert total > 0
      assert total == length(Ecto.Migrator.migrated_versions(Repo))

      insert_instance_admin("ops@example.com")

      assert {:ok, %{skipped: true, instance_admins: 1}} =
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

      assert FirstRun.provider_error({401, %{"error" => "Invalid token"}}) ==
               {401, "Invalid token"}

      assert FirstRun.provider_error({500, "<html>oops</html>"}) == {500, "<html>oops</html>"}
      assert FirstRun.provider_error(:smtp_down) == {nil, "smtp_down"}

      assert FirstRun.provider_error(%RuntimeError{message: "x"}) == {nil, "x"}
      assert {nil, "{:retries_exceeded, " <> _} = FirstRun.provider_error({:retries_exceeded, :x})
    end
  end
end

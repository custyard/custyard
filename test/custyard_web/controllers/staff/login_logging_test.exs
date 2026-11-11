defmodule CustyardWeb.Staff.LoginLoggingTest.MailerAdapter do
  use Swoosh.Adapter

  require Custyard.Log, as: Log

  def deliver(email, config) do
    send(self(), {:login_delivery_attempt, email})
    Log.info(:logging_self_test, stage: :deliver)

    case Keyword.get(config, :result, :accepted) do
      :accepted ->
        {:ok, %{id: "login-test-message", status: "queued"}}

      :provider_rejected ->
        {:error,
         {422,
          %{
            code: "validation_failed",
            errors: %{"from" => [email.html_body]},
            message: "UNTRUSTED_PROVIDER_ECHO",
            submitted_email: email
          }}}

      :transport_error ->
        {:error,
         {:untrusted_transport_error, %{message: "UNTRUSTED_TRANSPORT_ECHO", email: email}}}
    end
  end
end

defmodule CustyardWeb.Staff.LoginLoggingTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Custyard.{StaffAccount, RateLimit, Repo}
  alias Custyard.Auth.Account
  alias CustyardWeb.Staff.LoginLoggingTest.MailerAdapter

  @ip {10, 53, 1, 1}

  setup do
    RateLimit.reset()
    original_mailer = Application.fetch_env!(:custyard, Custyard.Mailer)
    Application.put_env(:custyard, Custyard.Mailer, adapter: MailerAdapter)

    on_exit(fn ->
      Application.put_env(:custyard, Custyard.Mailer, original_mailer)
      RateLimit.reset()
    end)

    :ok
  end

  test "logs the request and provider acceptance with the response request ID" do
    staff = insert_staff_account(role: "admin")
    {conn, log} = request_login(%{"email" => staff.email})

    assert redirected_to(conn) == "/app/login/sent"
    assert log =~ "http_request_started"
    assert log =~ "method=POST"
    assert log =~ "route=staff_login"

    assert_flow(log, conn, [
      "account_login_requested",
      "account_login_delivery_started",
      "account_login_provider_accepted"
    ])

    assert log =~ "account_id=#{staff.id}"
    assert_before(log, "account_login_delivery_started", "logging_self_test")
    assert_before(log, "logging_self_test", "account_login_provider_accepted")
    assert_received {:login_delivery_attempt, email}

    token = Repo.get!(StaffAccount, staff.id).login_token
    assert email.text_body =~ "/app/login/verify/#{token}"
    assert email.to == [{"", staff.email}]
    assert_no_secrets(log, staff)
  end

  test "logs an unknown account as skipped and preserves the generic redirect" do
    email = "unknown-login-#{System.unique_integer([:positive])}@example.com"
    {conn, log} = request_login(%{"email" => email})

    assert redirected_to(conn) == "/app/login/sent"
    assert_flow(log, conn, ["account_login_requested", "account_login_skipped"])
    assert log =~ "reason=unknown_account"
    refute log =~ email
    refute_received {:login_delivery_attempt, _}
    assert Repo.get_by(StaffAccount, email: email) == nil
  end

  test "deleting a customer leaves tenant staff login available" do
    organization = insert_organization()
    staff = insert_staff_account(role: "admin", tenant_id: organization.tenant_id)
    Repo.delete!(organization)
    {conn, log} = request_login(%{"email" => staff.email})
    assert redirected_to(conn) == "/app/login/sent"

    assert_flow(log, conn, [
      "account_login_requested",
      "account_login_delivery_started",
      "account_login_provider_accepted"
    ])

    assert Repo.get!(StaffAccount, staff.id).login_token
    assert_received {:login_delivery_attempt, _}
    assert_no_secrets(log, staff)
  end

  test "logs missing email while preserving the validation response" do
    {conn, log} = request_login(%{})

    assert html_response(conn, 200) =~ "Email is required."
    assert_flow(log, conn, ["account_login_requested", "account_login_skipped"])
    assert log =~ "reason=missing_email"
    refute_received {:login_delivery_attempt, _}
  end

  test "logs requests halted by the IP limiter and preserves the 429 response" do
    staff = insert_staff_account(role: "admin")
    exhaust_bucket(:account_login_ip, {staff.tenant_id, "10.53.1.1"})

    {conn, log} = request_login(%{"email" => staff.email})

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
    assert_flow(log, conn, ["account_login_requested", "account_login_skipped"])
    assert log =~ "reason=ip_rate_limited"
    assert Repo.get!(StaffAccount, staff.id).login_token == nil
    refute_received {:login_delivery_attempt, _}
    assert_no_secrets(log, staff)
  end

  test "logs the email rate limit and preserves the 429 response" do
    staff = insert_staff_account(role: "admin")
    exhaust_bucket(:account_login_email, {staff.tenant_id, staff.email})

    {conn, log} = request_login(%{"email" => staff.email})

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
    assert_flow(log, conn, ["account_login_requested", "account_login_skipped"])
    assert log =~ "reason=email_rate_limited"
    assert Repo.get!(StaffAccount, staff.id).login_token == nil
    refute_received {:login_delivery_attempt, _}
    assert_no_secrets(log, staff)
  end

  test "logs rejection status without a provider response that echoes the email" do
    Application.put_env(:custyard, Custyard.Mailer,
      adapter: MailerAdapter,
      result: :provider_rejected
    )

    staff = insert_staff_account(role: "admin")
    {conn, log} = request_login(%{"email" => staff.email})

    assert redirected_to(conn) == "/app/login/sent"

    assert_flow(log, conn, [
      "account_login_requested",
      "account_login_delivery_started",
      "account_login_provider_rejected"
    ])

    assert log =~ "account_id=#{staff.id}"
    assert log =~ "provider_status=422"
    assert log =~ "reason=provider_response"
    assert log =~ "provider_code=validation_failed"
    refute log =~ "UNTRUSTED_PROVIDER_ECHO"
    assert_received {:login_delivery_attempt, _}
    assert_no_secrets(log, staff)
  end

  test "logs a fixed reason for arbitrary transport errors that echo the email" do
    Application.put_env(:custyard, Custyard.Mailer,
      adapter: MailerAdapter,
      result: :transport_error
    )

    staff = insert_staff_account(role: "admin")
    {conn, log} = request_login(%{"email" => staff.email})

    assert redirected_to(conn) == "/app/login/sent"

    assert_flow(log, conn, [
      "account_login_requested",
      "account_login_delivery_started",
      "account_login_provider_rejected"
    ])

    assert log =~ "reason=unclassified_error"
    refute log =~ "provider_status="
    refute log =~ "untrusted_transport_error"
    refute log =~ "UNTRUSTED_TRANSPORT_ECHO"
    assert_received {:login_delivery_attempt, _}
    assert_no_secrets(log, staff)
  end

  test "safe provider validation fields reach the production JSON formatter" do
    Application.put_env(:custyard, Custyard.Mailer,
      adapter: MailerAdapter,
      result: :provider_rejected
    )

    staff = insert_staff_account(role: "admin")
    Logger.put_module_level(Custyard.Auth.LoginEmail, :info)
    on_exit(fn -> Logger.delete_module_level(Custyard.Auth.LoginEmail) end)

    {conn, records} =
      Custyard.LogCapture.with_json(fn ->
        build_conn()
        |> Map.put(:remote_ip, @ip)
        |> post("/app/login", %{"email" => staff.email})
      end)

    assert redirected_to(conn) == "/app/login/sent"
    rejected = Enum.find(records, &(&1["event"] == "account_login_provider_rejected"))
    assert rejected["provider_code"] == "validation_failed"
    assert rejected["provider_status"] == 422
    assert rejected["validation_fields"] == ["from"]
    assert rejected["request_id"] == hd(get_resp_header(conn, "x-request-id"))
    refute Jason.encode!(records) =~ staff.email
    refute Jason.encode!(records) =~ "/app/login/verify/"
  end

  test "a supplied request ID cannot smuggle personal data into logging" do
    private = "PRIVATE-HEADER-CANARY-/app/login/verify/request-secret"
    Logger.put_module_level(CustyardWeb.Plugs.RequestLog, :info)
    Logger.put_module_level(CustyardWeb.Staff.SessionController, :info)

    on_exit(fn ->
      Logger.delete_module_level(CustyardWeb.Plugs.RequestLog)
      Logger.delete_module_level(CustyardWeb.Staff.SessionController)
    end)

    {conn, log} =
      with_log(Application.fetch_env!(:logger, :console), fn ->
        build_conn()
        |> Map.put(:remote_ip, @ip)
        |> put_req_header("x-request-id", private)
        |> post("/app/login", %{})
      end)

    assert [request_id] = get_resp_header(conn, "x-request-id")
    refute request_id == private
    assert log =~ request_id
    refute log =~ private
    refute log =~ "request-secret"
  end

  test "successful token consumption records the authenticated staff without a request URL" do
    staff =
      insert_staff_account(role: "admin")
      |> Account.login_token_changeset()
      |> Repo.update!()

    token = staff.login_token
    {conn, log} = capture_login(fn -> post(build_conn(), "/app/login/verify/#{token}") end)

    assert redirected_to(conn) == "/app"
    assert get_session(conn, :staff_id) == staff.id
    assert get_session(conn, :staff_claim) == StaffAccount.session_claim(staff)
    assert Repo.get!(StaffAccount, staff.id).login_token == nil
    assert_flow(log, conn, ["account_login_succeeded"])
    assert log =~ "staff_id=#{staff.id}"
    refute log =~ "http_request_started"
    refute log =~ "http_request_completed"
    refute log =~ token
    assert_no_secrets(log, staff)

    {replayed, replay_log} =
      capture_login(fn -> post(build_conn(), "/app/login/verify/#{token}") end)

    assert html_response(replayed, 200) =~ "Invalid or expired login link"
    refute get_session(replayed, :staff_id)
    assert_flow(replay_log, replayed, ["account_login_rejected"])
    assert replay_log =~ "reason=invalid_or_expired_token"
    refute replay_log =~ "staff_id="
    refute replay_log =~ token
  end

  test "expired, unknown and malformed token attempts get a fixed token-free rejection" do
    staff =
      insert_staff_account(role: "admin")
      |> Account.login_token_changeset()
      |> Repo.update!()

    expired_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    staff |> Ecto.Changeset.change(login_token_expires_at: expired_at) |> Repo.update!()

    for {token, response} <- [
          {staff.login_token, "has expired"},
          {String.duplicate("x", 43), "Invalid or expired login link"},
          {"not%20a%20token", "Invalid or expired login link"}
        ] do
      {conn, log} = capture_login(fn -> post(build_conn(), "/app/login/verify/#{token}") end)

      assert html_response(conn, 200) =~ response
      refute get_session(conn, :staff_id)
      assert_flow(log, conn, ["account_login_rejected"])
      assert log =~ "reason=invalid_or_expired_token"
      refute log =~ "staff_id="
      refute log =~ "http_request_started"
      refute log =~ "http_request_completed"
      refute log =~ token
      assert_no_secrets(log, staff)
    end
  end

  # A suspended workspace never reaches the session controller: the host plug
  # answers before any account is read, so no login event names an account.
  test "a valid token on a suspended workspace is refused before any account is read" do
    staff =
      insert_staff_account(role: "admin")
      |> Account.login_token_changeset()
      |> Repo.update!()

    Custyard.Tenants.get_tenant!(staff.tenant_id)
    |> Ecto.Changeset.change(status: "suspended")
    |> Repo.update!()

    {conn, log} =
      capture_login(fn -> post(build_conn(), "/app/login/verify/#{staff.login_token}") end)

    assert conn.status == 403
    assert conn.halted
    refute log =~ "account_login_"
    refute log =~ "staff_id="
    refute log =~ staff.login_token
    assert Repo.get!(StaffAccount, staff.id).login_token == staff.login_token
  end

  test "logout records the signed session identity without claiming current account validation" do
    staff = insert_staff_account(role: "admin")

    {conn, log} =
      capture_login(fn ->
        build_conn()
        |> init_test_session(%{staff_id: staff.id, staff_claim: "stale-session-claim"})
        |> delete("/app/logout")
      end)

    assert redirected_to(conn) == "/app/login"
    refute get_session(conn, :staff_id)
    refute get_session(conn, :staff_claim)
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert log =~ "account_logout"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "session_staff_id=#{staff.id}"
    refute Regex.match?(~r/(?:^|\s)staff_id=/, log)
    refute log =~ "stale-session-claim"
    assert_no_secrets(log, staff)
  end

  test "logout remains available without a numeric session identity and never logs session claims" do
    for staff_id <- [nil, "PRIVATE-SESSION-IDENTITY-CANARY"] do
      {conn, log} =
        capture_login(fn ->
          build_conn()
          |> init_test_session(%{
            staff_id: staff_id,
            staff_claim: "PRIVATE-CLAIM-CANARY"
          })
          |> delete("/app/logout")
        end)

      assert redirected_to(conn) == "/app/login"
      refute get_session(conn, :staff_id)
      refute get_session(conn, :staff_claim)
      assert log =~ "account_logout"
      assert log =~ "request_id=#{hd(get_resp_header(conn, "x-request-id"))}"
      refute log =~ "session_staff_id="
      refute Regex.match?(~r/(?:^|\s)staff_id=/, log)
      refute log =~ "PRIVATE-SESSION-IDENTITY-CANARY"
      refute log =~ "PRIVATE-CLAIM-CANARY"
    end
  end

  defp request_login(params) do
    capture_login(fn ->
      build_conn()
      |> Map.put(:remote_ip, @ip)
      |> post("/app/login", params)
    end)
  end

  defp capture_login(fun) do
    # Use the application's real formatter and metadata allowlist so these
    # assertions also catch fields accidentally hidden from production logs.
    capture_options = Application.fetch_env!(:logger, :console) |> Keyword.put(:level, :info)

    modules = [
      CustyardWeb.Staff.SessionController,
      Custyard.Auth.LoginEmail,
      Phoenix.Logger,
      CustyardWeb.Plugs.RequestLog,
      MailerAdapter
    ]

    previous_levels = Logger.get_module_level(modules)

    # Module overrides can enable info below the test config's warning level;
    # process overrides only restrict logging further.
    Enum.each(modules, &Logger.put_module_level(&1, :info))

    try do
      with_log(capture_options, fun)
    after
      Enum.each(modules, &Logger.delete_module_level/1)
      Enum.each(previous_levels, fn {module, level} -> Logger.put_module_level(module, level) end)
    end
  end

  defp assert_flow(log, conn, expected_events) do
    events = Regex.scan(~r/\[info\] (account_login_[a-z_]+)$/m, log, capture: :all_but_first)
    assert List.flatten(events) == expected_events
    assert [request_id] = get_resp_header(conn, "x-request-id")

    for line <- String.split(log, "\n"), Regex.match?(~r/\] account_login_[a-z_]+$/, line) do
      assert line =~ "[info]"
      assert line =~ "request_id=#{request_id}"
    end
  end

  defp assert_before(log, first, second) do
    assert {first_offset, _} = :binary.match(log, first)
    assert {second_offset, _} = :binary.match(log, second)
    assert first_offset < second_offset
  end

  defp assert_no_secrets(log, staff) do
    refute log =~ staff.email
    refute log =~ "/app/login/verify/"

    if token = Repo.get!(StaffAccount, staff.id).login_token do
      refute log =~ token
    end
  end

  defp exhaust_bucket(bucket, key) do
    {limit, _window_ms} = RateLimit.bucket_config!(bucket)

    for _ <- 1..limit do
      assert {:allow, _} = RateLimit.check_rate(bucket, key)
    end
  end
end

defmodule CustyardWeb.Operator.LoginLoggingTest.MailerAdapter do
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

defmodule CustyardWeb.Operator.LoginLoggingTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Custyard.{OperatorAccount, RateLimit, Repo}
  alias CustyardWeb.Operator.LoginLoggingTest.MailerAdapter

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
    operator = insert_operator_account()
    {conn, log} = request_login(%{"email" => operator.email})

    assert redirected_to(conn) == "/operator/login/sent"
    assert log =~ "http_request_started"
    assert log =~ "method=POST"
    assert log =~ "route=operator_login"

    assert_flow(log, conn, [
      "operator_login_requested",
      "operator_login_delivery_started",
      "operator_login_provider_accepted"
    ])

    assert log =~ "operator_id=#{operator.id}"
    assert_before(log, "operator_login_delivery_started", "logging_self_test")
    assert_before(log, "logging_self_test", "operator_login_provider_accepted")
    assert_received {:login_delivery_attempt, email}

    token = Repo.get!(OperatorAccount, operator.id).login_token
    assert email.text_body =~ "/operator/login/verify/#{token}"
    assert email.to == [{"", operator.email}]
    assert_no_secrets(log, operator)
  end

  test "logs an unknown account as skipped and preserves the generic redirect" do
    email = "unknown-login-#{System.unique_integer([:positive])}@example.com"
    {conn, log} = request_login(%{"email" => email})

    assert redirected_to(conn) == "/operator/login/sent"
    assert_flow(log, conn, ["operator_login_requested", "operator_login_skipped"])
    assert log =~ "reason=unknown_account"
    refute log =~ email
    refute_received {:login_delivery_attempt, _}
    assert Repo.get_by(OperatorAccount, email: email) == nil
  end

  test "logs a missing organization without generating a token or sending mail" do
    organization = insert_organization()
    operator = insert_operator_account(role: "admin", organization_id: organization.id)
    Repo.delete!(organization)

    {conn, log} = request_login(%{"email" => operator.email})

    assert redirected_to(conn) == "/operator/login/sent"
    assert_flow(log, conn, ["operator_login_requested", "operator_login_skipped"])
    assert log =~ "reason=no_organization"
    assert log =~ "operator_id=#{operator.id}"
    assert Repo.get!(OperatorAccount, operator.id).login_token == nil
    refute_received {:login_delivery_attempt, _}
    assert_no_secrets(log, operator)
  end

  test "logs missing email while preserving the validation response" do
    {conn, log} = request_login(%{})

    assert html_response(conn, 200) =~ "Email is required."
    assert_flow(log, conn, ["operator_login_requested", "operator_login_skipped"])
    assert log =~ "reason=missing_email"
    refute_received {:login_delivery_attempt, _}
  end

  test "logs requests halted by the IP limiter and preserves the 429 response" do
    operator = insert_operator_account()
    exhaust_bucket(:operator_login_ip, "10.53.1.1")

    {conn, log} = request_login(%{"email" => operator.email})

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
    assert_flow(log, conn, ["operator_login_requested", "operator_login_skipped"])
    assert log =~ "reason=ip_rate_limited"
    assert Repo.get!(OperatorAccount, operator.id).login_token == nil
    refute_received {:login_delivery_attempt, _}
    assert_no_secrets(log, operator)
  end

  test "logs the email rate limit and preserves the 429 response" do
    operator = insert_operator_account()
    exhaust_bucket(:operator_login_email, operator.email)

    {conn, log} = request_login(%{"email" => operator.email})

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
    assert_flow(log, conn, ["operator_login_requested", "operator_login_skipped"])
    assert log =~ "reason=email_rate_limited"
    assert Repo.get!(OperatorAccount, operator.id).login_token == nil
    refute_received {:login_delivery_attempt, _}
    assert_no_secrets(log, operator)
  end

  test "logs rejection status without a provider response that echoes the email" do
    Application.put_env(:custyard, Custyard.Mailer,
      adapter: MailerAdapter,
      result: :provider_rejected
    )

    operator = insert_operator_account()
    {conn, log} = request_login(%{"email" => operator.email})

    assert redirected_to(conn) == "/operator/login/sent"

    assert_flow(log, conn, [
      "operator_login_requested",
      "operator_login_delivery_started",
      "operator_login_provider_rejected"
    ])

    assert log =~ "operator_id=#{operator.id}"
    assert log =~ "provider_status=422"
    assert log =~ "reason=provider_response"
    assert log =~ "provider_code=validation_failed"
    refute log =~ "UNTRUSTED_PROVIDER_ECHO"
    assert_received {:login_delivery_attempt, _}
    assert_no_secrets(log, operator)
  end

  test "logs a fixed reason for arbitrary transport errors that echo the email" do
    Application.put_env(:custyard, Custyard.Mailer,
      adapter: MailerAdapter,
      result: :transport_error
    )

    operator = insert_operator_account()
    {conn, log} = request_login(%{"email" => operator.email})

    assert redirected_to(conn) == "/operator/login/sent"

    assert_flow(log, conn, [
      "operator_login_requested",
      "operator_login_delivery_started",
      "operator_login_provider_rejected"
    ])

    assert log =~ "reason=unclassified_error"
    refute log =~ "provider_status="
    refute log =~ "untrusted_transport_error"
    refute log =~ "UNTRUSTED_TRANSPORT_ECHO"
    assert_received {:login_delivery_attempt, _}
    assert_no_secrets(log, operator)
  end

  test "safe provider validation fields reach the production JSON formatter" do
    Application.put_env(:custyard, Custyard.Mailer,
      adapter: MailerAdapter,
      result: :provider_rejected
    )

    operator = insert_operator_account()
    Logger.put_module_level(Custyard.Auth.LoginEmail, :info)
    on_exit(fn -> Logger.delete_module_level(Custyard.Auth.LoginEmail) end)

    {conn, records} =
      Custyard.LogCapture.with_json(fn ->
        build_conn()
        |> Map.put(:remote_ip, @ip)
        |> post("/operator/login", %{"email" => operator.email})
      end)

    assert redirected_to(conn) == "/operator/login/sent"
    rejected = Enum.find(records, &(&1["event"] == "operator_login_provider_rejected"))
    assert rejected["provider_code"] == "validation_failed"
    assert rejected["provider_status"] == 422
    assert rejected["validation_fields"] == ["from"]
    assert rejected["request_id"] == hd(get_resp_header(conn, "x-request-id"))
    refute Jason.encode!(records) =~ operator.email
    refute Jason.encode!(records) =~ "/operator/login/verify/"
  end

  test "a supplied request ID cannot smuggle personal data into logging" do
    private = "PRIVATE-HEADER-CANARY-/operator/login/verify/request-secret"
    Logger.put_module_level(CustyardWeb.Plugs.RequestLog, :info)
    Logger.put_module_level(CustyardWeb.Operator.SessionController, :info)

    on_exit(fn ->
      Logger.delete_module_level(CustyardWeb.Plugs.RequestLog)
      Logger.delete_module_level(CustyardWeb.Operator.SessionController)
    end)

    {conn, log} =
      with_log(Application.fetch_env!(:logger, :console), fn ->
        build_conn()
        |> Map.put(:remote_ip, @ip)
        |> put_req_header("x-request-id", private)
        |> post("/operator/login", %{})
      end)

    assert [request_id] = get_resp_header(conn, "x-request-id")
    refute request_id == private
    assert log =~ request_id
    refute log =~ private
    refute log =~ "request-secret"
  end

  test "successful token consumption records the authenticated operator without a request URL" do
    operator =
      insert_operator_account()
      |> OperatorAccount.login_token_changeset()
      |> Repo.update!()

    token = operator.login_token
    {conn, log} = capture_login(fn -> post(build_conn(), "/operator/login/verify/#{token}") end)

    assert redirected_to(conn) == "/operator"
    assert get_session(conn, :operator_id) == operator.id
    assert get_session(conn, :operator_claim) == OperatorAccount.session_claim(operator)
    assert Repo.get!(OperatorAccount, operator.id).login_token == nil
    assert_flow(log, conn, ["operator_login_succeeded"])
    assert log =~ "operator_id=#{operator.id}"
    refute log =~ "http_request_started"
    refute log =~ "http_request_completed"
    refute log =~ token
    assert_no_secrets(log, operator)

    {replayed, replay_log} =
      capture_login(fn -> post(build_conn(), "/operator/login/verify/#{token}") end)

    assert html_response(replayed, 200) =~ "Invalid or expired login link"
    refute get_session(replayed, :operator_id)
    assert_flow(replay_log, replayed, ["operator_login_rejected"])
    assert replay_log =~ "reason=invalid_or_expired_token"
    refute replay_log =~ "operator_id="
    refute replay_log =~ token
  end

  test "expired, unknown and malformed token attempts get a fixed token-free rejection" do
    operator =
      insert_operator_account()
      |> OperatorAccount.login_token_changeset()
      |> Repo.update!()

    expired_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    operator |> Ecto.Changeset.change(login_token_expires_at: expired_at) |> Repo.update!()

    for {token, response} <- [
          {operator.login_token, "has expired"},
          {String.duplicate("x", 43), "Invalid or expired login link"},
          {"not%20a%20token", "Invalid or expired login link"}
        ] do
      {conn, log} = capture_login(fn -> post(build_conn(), "/operator/login/verify/#{token}") end)

      assert html_response(conn, 200) =~ response
      refute get_session(conn, :operator_id)
      assert_flow(log, conn, ["operator_login_rejected"])
      assert log =~ "reason=invalid_or_expired_token"
      refute log =~ "operator_id="
      refute log =~ "http_request_started"
      refute log =~ "http_request_completed"
      refute log =~ token
      assert_no_secrets(log, operator)
    end
  end

  test "a valid token with no organization is rejected without naming an account" do
    organization = insert_organization()

    operator =
      insert_operator_account(role: "admin", organization_id: organization.id)
      |> OperatorAccount.login_token_changeset()
      |> Repo.update!()

    Repo.delete!(organization)

    {conn, log} =
      capture_login(fn ->
        post(build_conn(), "/operator/login/verify/#{operator.login_token}")
      end)

    assert html_response(conn, 200) =~ "No organization assigned; ask a super admin."
    refute get_session(conn, :operator_id)
    assert_flow(log, conn, ["operator_login_rejected"])
    assert log =~ "reason=no_organization"
    refute log =~ "operator_id="
    refute log =~ operator.login_token
    assert_no_secrets(log, operator)
  end

  test "logout records the signed session identity without claiming current account validation" do
    operator = insert_operator_account()

    {conn, log} =
      capture_login(fn ->
        build_conn()
        |> init_test_session(%{operator_id: operator.id, operator_claim: "stale-session-claim"})
        |> delete("/operator/logout")
      end)

    assert redirected_to(conn) == "/operator/login"
    refute get_session(conn, :operator_id)
    refute get_session(conn, :operator_claim)
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert log =~ "operator_logout"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "session_operator_id=#{operator.id}"
    refute Regex.match?(~r/(?:^|\s)operator_id=/, log)
    refute log =~ "stale-session-claim"
    assert_no_secrets(log, operator)
  end

  test "logout remains available without a numeric session identity and never logs session claims" do
    for operator_id <- [nil, "PRIVATE-SESSION-IDENTITY-CANARY"] do
      {conn, log} =
        capture_login(fn ->
          build_conn()
          |> init_test_session(%{
            operator_id: operator_id,
            operator_claim: "PRIVATE-CLAIM-CANARY"
          })
          |> delete("/operator/logout")
        end)

      assert redirected_to(conn) == "/operator/login"
      refute get_session(conn, :operator_id)
      refute get_session(conn, :operator_claim)
      assert log =~ "operator_logout"
      assert log =~ "request_id=#{hd(get_resp_header(conn, "x-request-id"))}"
      refute log =~ "session_operator_id="
      refute Regex.match?(~r/(?:^|\s)operator_id=/, log)
      refute log =~ "PRIVATE-SESSION-IDENTITY-CANARY"
      refute log =~ "PRIVATE-CLAIM-CANARY"
    end
  end

  defp request_login(params) do
    capture_login(fn ->
      build_conn()
      |> Map.put(:remote_ip, @ip)
      |> post("/operator/login", params)
    end)
  end

  defp capture_login(fun) do
    # Use the application's real formatter and metadata allowlist so these
    # assertions also catch fields accidentally hidden from production logs.
    capture_options = Application.fetch_env!(:logger, :console) |> Keyword.put(:level, :info)

    modules = [
      CustyardWeb.Operator.SessionController,
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
    events = Regex.scan(~r/\[info\] (operator_login_[a-z_]+)$/m, log, capture: :all_but_first)
    assert List.flatten(events) == expected_events
    assert [request_id] = get_resp_header(conn, "x-request-id")

    for line <- String.split(log, "\n"), Regex.match?(~r/\] operator_login_[a-z_]+$/, line) do
      assert line =~ "[info]"
      assert line =~ "request_id=#{request_id}"
    end
  end

  defp assert_before(log, first, second) do
    assert {first_offset, _} = :binary.match(log, first)
    assert {second_offset, _} = :binary.match(log, second)
    assert first_offset < second_offset
  end

  defp assert_no_secrets(log, operator) do
    refute log =~ operator.email
    refute log =~ "/operator/login/verify/"

    if token = Repo.get!(OperatorAccount, operator.id).login_token do
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

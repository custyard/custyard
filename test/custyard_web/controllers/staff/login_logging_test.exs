defmodule CustyardWeb.Staff.LoginLoggingTest.MailerAdapter do
  use Swoosh.Adapter

  require Logger

  def deliver(email, config) do
    send(self(), {:login_delivery_attempt, email})
    Logger.info("login_test_adapter_called")

    case Keyword.get(config, :result, :accepted) do
      :accepted ->
        {:ok, %{id: "login-test-message", status: "queued"}}

      :provider_rejected ->
        {:error, {422, %{message: "UNTRUSTED_PROVIDER_ECHO", submitted_email: email}}}

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
    assert log =~ "POST /app/login"

    assert_flow(log, conn, [
      "account_login_requested",
      "account_login_delivery_started",
      "account_login_provider_accepted"
    ])

    assert log =~ "account_id=#{staff.id}"
    assert_before(log, "account_login_delivery_started", "login_test_adapter_called")
    assert_before(log, "login_test_adapter_called", "account_login_provider_accepted")
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

    assert log =~ "reason=delivery_error"
    refute log =~ "provider_status="
    refute log =~ "untrusted_transport_error"
    refute log =~ "UNTRUSTED_TRANSPORT_ECHO"
    assert_received {:login_delivery_attempt, _}
    assert_no_secrets(log, staff)
  end

  defp request_login(params) do
    # Use the application's real formatter and metadata allowlist so these
    # assertions also catch fields accidentally hidden from production logs.
    capture_options = Application.fetch_env!(:logger, :console) |> Keyword.put(:level, :info)

    modules = [
      CustyardWeb.Staff.SessionController,
      Custyard.Auth.LoginEmail,
      Phoenix.Logger,
      MailerAdapter
    ]

    previous_levels = Logger.get_module_level(modules)

    # Module overrides can enable info below the test config's warning level;
    # process overrides only restrict logging further.
    Enum.each(modules, &Logger.put_module_level(&1, :info))

    try do
      with_log(capture_options, fn ->
        build_conn()
        |> Map.put(:remote_ip, @ip)
        |> post("/app/login", params)
      end)
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

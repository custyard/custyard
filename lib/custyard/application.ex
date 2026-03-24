defmodule Custyard.Application do
  @moduledoc false

  use Application

  require Logger

  @default_operator_email "admin@custyard.local"

  @impl true
  def start(_type, _args) do
    children =
      [
        CustyardWeb.Telemetry,
        Custyard.Repo,
        {DNSCluster, query: Application.get_env(:custyard, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Custyard.PubSub},
        {Finch, name: Custyard.Finch},
        CustyardWeb.Endpoint
      ]
      |> maybe_add_scheduler()
      |> maybe_add_lmtp_server()
      |> maybe_add_imap_poller()

    opts = [strategy: :one_for_one, name: Custyard.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Setup operator account after supervisor fully starts
    # Use Task to avoid blocking application startup
    if Application.get_env(:custyard, :env) == :dev do
      Task.start(fn -> setup_dev_operator() end)
    end

    result
  end

  defp maybe_add_scheduler(children) do
    if Application.get_env(:custyard, :start_scheduler, true) do
      [Custyard.Scoring.Scheduler | children]
    else
      children
    end
  end

  defp maybe_add_lmtp_server(children) do
    lmtp_config = Application.get_env(:custyard, :lmtp, [])

    if Keyword.get(lmtp_config, :enabled, false) do
      port = Keyword.get(lmtp_config, :port, 2024)
      hostname = Keyword.get(lmtp_config, :hostname, "localhost")
      tls_opts = Keyword.get(lmtp_config, :tls, [])
      max_received_count = Keyword.get(lmtp_config, :max_received_count, 3)

      opts = [
        port: port,
        hostname: hostname,
        tls: tls_opts,
        max_received_count: max_received_count
      ]

      [{Custyard.Email.LMTPServer, opts} | children]
    else
      children
    end
  end

  defp maybe_add_imap_poller(children) do
    imap_config = Application.get_env(:custyard, :imap, [])

    if Keyword.get(imap_config, :enabled, false) do
      opts = [
        host: Keyword.get(imap_config, :host, "localhost"),
        port: Keyword.get(imap_config, :port, 993),
        username: Keyword.get(imap_config, :username, ""),
        password: Keyword.get(imap_config, :password, ""),
        folder: Keyword.get(imap_config, :folder, "INBOX"),
        poll_interval: Keyword.get(imap_config, :poll_interval, 60_000),
        ssl: Keyword.get(imap_config, :ssl, true)
      ]

      [{Custyard.Email.ImapPoller, opts} | children]
    else
      children
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CustyardWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_dev_operator do
    alias Custyard.{OperatorAccount, Repo}

    # Brief delay to ensure Repo is ready
    Process.sleep(100)

    password = generate_password()

    case Repo.get_by(OperatorAccount, email: @default_operator_email) do
      nil ->
        # First startup: create operator
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: @default_operator_email, password: password})
        |> Repo.insert!()

        log_operator_credentials(@default_operator_email, password, :created)

      operator ->
        # Subsequent startup: reset password
        operator
        |> OperatorAccount.password_changeset(%{password: password})
        |> Repo.update!()

        log_operator_credentials(@default_operator_email, password, :reset)
    end
  rescue
    e ->
      Logger.warning("Failed to setup dev operator: #{inspect(e)}")
  end

  defp generate_password do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64() |> binary_part(0, 16)
  end

  defp log_operator_credentials(email, password, action) do
    action_text = if action == :created, do: "Created", else: "Reset password for"

    Logger.info("""

    ========================================
    OPERATOR ACCOUNT #{String.upcase(to_string(action))}
    ========================================
    #{action_text} operator account:

      Email:    #{email}
      Password: #{password}

    Login at: /operator/login
    ========================================
    """)
  end
end

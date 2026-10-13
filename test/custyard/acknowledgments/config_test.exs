defmodule Custyard.Acknowledgments.ConfigTest do
  # Mutates process-global env vars and application config, and reads
  # config/runtime.exs: sequential only.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias Custyard.Acknowledgments
  alias Custyard.Acknowledgments.{Config, Consumer}
  # `Config` above is the module under test.
  alias Elixir.Config.Reader, as: ConfigReader

  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)
  @password "broker-s3cret"
  @env_vars ~w(ACKNOWLEDGMENTS_ENABLED ACKNOWLEDGMENTS_PREFETCH ACKNOWLEDGMENTS_AMQP_URL ACKNOWLEDGMENTS_SOURCE MAIL_ADAPTER SECRET_KEY_BASE DATABASE_URL)

  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_config = Application.get_env(:custyard, :acknowledgments)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Application.put_env(:custyard, :acknowledgments, saved_config)
    end)

    Enum.each(
      ~w(ACKNOWLEDGMENTS_ENABLED ACKNOWLEDGMENTS_PREFETCH DATABASE_URL),
      &System.delete_env/1
    )

    :ok
  end

  defp config(overrides) do
    Keyword.merge(
      [
        enabled: true,
        url: nil,
        source: nil,
        queue: "custyard.acknowledgments",
        prefetch: 1,
        retry_delays: [10_000],
        confirm_timeout: 5_000,
        reconnect_delay: 5_000
      ],
      overrides
    )
  end

  defp acknowledgments(env) do
    ConfigReader.read!(@runtime_config, env: env)[:custyard][:acknowledgments]
  end

  # A prod read needs the settings prod refuses to boot without; the mail and
  # Lettermint warnings it prints are expected here.
  defp prod_acknowledgments do
    System.put_env("MAIL_ADAPTER", "local")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    {result, _warnings} = with_io(:stderr, fn -> acknowledgments(:prod) end)
    result
  end

  describe "ACKNOWLEDGMENTS_ENABLED in config/runtime.exs" do
    test "unset or empty means enabled in production" do
      assert prod_acknowledgments()[:enabled] == true

      System.put_env("ACKNOWLEDGMENTS_ENABLED", "")
      assert prod_acknowledgments()[:enabled] == true
    end

    # A shell holding production broker secrets must never consume the
    # production queue by accident.
    test "unset means disabled in dev and test" do
      assert acknowledgments(:dev)[:enabled] == false
      assert acknowledgments(:test)[:enabled] == false
    end

    test "explicit values work everywhere" do
      System.put_env("ACKNOWLEDGMENTS_ENABLED", "false")
      assert prod_acknowledgments()[:enabled] == false

      System.put_env("ACKNOWLEDGMENTS_ENABLED", "true")
      assert acknowledgments(:dev)[:enabled] == true
    end

    test "any other value, or a bad prefetch, refuses to boot" do
      System.put_env("ACKNOWLEDGMENTS_ENABLED", "yes")
      assert_raise RuntimeError, ~r/must be true or false/, fn -> acknowledgments(:dev) end

      System.delete_env("ACKNOWLEDGMENTS_ENABLED")
      System.put_env("ACKNOWLEDGMENTS_PREFETCH", "0")
      assert_raise RuntimeError, ~r/between 1 and 100/, fn -> acknowledgments(:dev) end
    end

    # Completeness is decided at application start, so bin/operator still
    # boots while acknowledgment secrets are half set.
    test "an incomplete URL and source still reads" do
      System.put_env("ACKNOWLEDGMENTS_SOURCE", "ots.eu.production")
      System.delete_env("ACKNOWLEDGMENTS_AMQP_URL")

      assert %{enabled: true, url: nil, source: "ots.eu.production"} =
               Map.new(prod_acknowledgments())
    end
  end

  describe "startup/2" do
    test "disabled starts nothing and says nothing" do
      assert capture_log(fn ->
               assert Config.startup(config(enabled: false), :prod) == :disabled
             end) ==
               ""
    end

    test "enabled without URL or source logs the variable names once" do
      log =
        capture_log(fn -> assert Config.startup(config([]), :prod) == :not_configured end)

      assert log =~ "ACKNOWLEDGMENTS_AMQP_URL"
      assert log =~ "ACKNOWLEDGMENTS_SOURCE"
    end

    test "exactly one of URL and source refuses to start, naming the missing one" do
      url = "amqp://custyard:#{@password}@broker.internal/ots"

      error =
        assert_raise ArgumentError, fn -> Config.startup(config(url: url), :prod) end

      assert error.message =~ "ACKNOWLEDGMENTS_SOURCE is not set"
      refute error.message =~ @password

      error =
        assert_raise ArgumentError, fn ->
          Config.startup(config(source: "ots.eu.production"), :prod)
        end

      assert error.message =~ "ACKNOWLEDGMENTS_AMQP_URL is not set"
    end

    # A malformed URL used to become a silent five-second reconnect loop.
    test "a URL that does not parse refuses to start without echoing it" do
      for url <- [
            "amqp://custyard:#{@password}@broker.internal:99999",
            "amqp://custyard:#{@password}@broker.internal/vhost/extra",
            "amqp://",
            "http://custyard:#{@password}@broker.internal"
          ] do
        error =
          assert_raise ArgumentError, fn ->
            Config.startup(config(url: url, source: "ots.eu.production"), :prod)
          end

        refute error.message =~ @password
        refute error.message =~ "broker.internal"
      end
    end

    test "complete configuration starts; plaintext to a remote host warns in prod only" do
      remote = config(url: "amqp://custyard:#{@password}@broker.example.com", source: "ots.test")

      log = capture_log(fn -> assert Config.startup(remote, :prod) == :enabled end)
      assert log =~ "plaintext amqp"
      refute log =~ @password
      refute log =~ "broker.example.com"

      assert capture_log(fn -> Config.startup(remote, :dev) end) == ""

      for url <- [
            "amqp://u:p@localhost",
            "amqp://u:p@127.0.0.1:5672",
            "amqp://u:p@custyard-rabbit.internal",
            "amqp://u:p@rabbit.flycast/ots",
            "amqps://u:p@broker.example.com?cacertfile=/etc/ssl/certs/ca-certificates.crt&verify=verify_peer"
          ] do
        log =
          capture_log(fn ->
            assert Config.startup(config(url: url, source: "ots.test"), :prod) == :enabled
          end)

        refute log =~ "plaintext", "unexpected warning for #{url}"
      end
    end

    test "amqps without certificate verification refuses a remote host, in every environment" do
      unverified =
        "amqps://custyard:#{@password}@broker.example.com:5671/ots?" <>
          "cacertfile=/etc/ssl/certs/ca-certificates.crt&verify=verify_none"

      for env <- [:prod, :dev] do
        error =
          assert_raise ArgumentError, fn ->
            Config.startup(config(url: unverified, source: "ots.test"), env)
          end

        assert error.message =~ "verify=verify_peer"
        refute error.message =~ @password
        refute error.message =~ "broker.example.com"
      end

      assert Config.validation_error(config(url: unverified, source: "ots.test")) =~
               "TLS certificate verification"

      # Omitting verify keeps OTP's default, verify_peer; local and Fly
      # private hosts may opt out, as they may use plaintext.
      for url <- [
            "amqps://u:p@broker.example.com?cacertfile=/etc/ssl/certs/ca-certificates.crt",
            "amqps://u:p@localhost?verify=verify_none",
            "amqps://u:p@rabbit.internal?verify=verify_none",
            "amqps://u:p@rabbit.flycast/ots?verify=verify_none"
          ] do
        log =
          capture_log(fn ->
            assert Config.startup(config(url: url, source: "ots.test"), :prod) == :enabled
          end)

        refute log =~ "plaintext", "unexpected warning for #{url}"
      end
    end
  end

  describe "subscription status and overview" do
    test "follow configuration without waiting on a consumer" do
      Application.put_env(:custyard, :acknowledgments, config(enabled: false))
      assert Acknowledgments.subscription_status() == :disabled

      Application.put_env(:custyard, :acknowledgments, config([]))
      assert Acknowledgments.subscription_status() == :not_configured

      Application.put_env(:custyard, :acknowledgments, config(source: "ots.test"))
      assert Acknowledgments.subscription_status() == :not_configured

      url = "amqp://custyard:#{@password}@broker.internal"
      Application.put_env(:custyard, :acknowledgments, config(url: url, source: "ots.test"))
      refute Process.whereis(Consumer)
      assert Acknowledgments.subscription_status() == :connecting
    end

    test "the overview never carries the URL" do
      url = "amqp://custyard:#{@password}@broker.internal"
      Application.put_env(:custyard, :acknowledgments, config(url: url, source: "ots.test"))

      overview = Acknowledgments.subscription_overview()

      assert %{
               status: :connecting,
               broker_configured?: true,
               source: "ots.test",
               queue: "custyard.acknowledgments",
               prefetch: 1,
               required_variables: ["ACKNOWLEDGMENTS_AMQP_URL", "ACKNOWLEDGMENTS_SOURCE"]
             } = overview

      refute inspect(overview) =~ @password
      refute inspect(overview) =~ "broker.internal"
    end
  end

  test "consumer status output redacts the URL" do
    state = %{config: config(url: "amqp://custyard:#{@password}@broker.internal"), channel: nil}

    formatted = Consumer.format_status(%{state: state, message: :connect, reason: :normal})

    assert formatted.state.config[:url] == "[REDACTED]"
    assert formatted.message == :connect
    refute inspect(formatted) =~ @password
  end
end

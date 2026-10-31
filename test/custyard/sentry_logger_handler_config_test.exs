defmodule Custyard.SentryLoggerHandlerConfigTest do
  # Logger handlers are global; register a separate handler without restarting
  # Logger or altering its primary privacy filter.
  use ExUnit.Case, async: false

  test "the installed SDK validates the application's exact capture options" do
    assert Application.get_env(:sentry, :dsn) == nil
    primary_config = :logger.get_primary_config()
    handler = :custyard_sentry_sdk_config_test
    on_exit(fn -> :logger.remove_handler(handler) end)

    assert :ok =
             :logger.add_handler(
               handler,
               Sentry.LoggerHandler,
               Custyard.Sentry.logger_handler_config()
             )

    assert {:ok, %{module: Sentry.LoggerHandler, config: config}} =
             :logger.get_handler_config(handler)

    assert %Sentry.LoggerHandler{} = config
    assert config.capture_log_messages == true
    assert config.capture_level == :error
    assert config.capture_metadata == :all
    assert config.tags_from_metadata == [:custyard_event, :request_id, :operation_id, :error_type]
    assert Sentry.LoggerHandler.ErrorBackend in config.backends
    assert :logger.get_primary_config() == primary_config
  end
end

defmodule Custyard.MailAdapterConfigTest do
  # Mutates process-global env vars and reads config/runtime.exs — sequential only.
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @env_vars ~w(MAIL_ADAPTER LETTERMINT_PROJECT_TOKEN LETTERMINT_API_KEY SECRET_KEY_BASE PHX_HOST)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(@env_vars, &System.delete_env/1)
    :ok
  end

  defp read_prod_config! do
    Config.Reader.read!(@runtime_config, env: :prod)[:custyard]
  end

  defp mail_problems(config) do
    Enum.filter(config[:boot_env].problems, &(&1.variable == "MAIL_ADAPTER"))
  end

  describe "MAIL_ADAPTER in :prod" do
    # Operator login is magic-link-only, so silently keeping the in-memory
    # Local adapter locks everyone out with no error anywhere. The problem is
    # reported in the boot verdict (Custyard.Boot.Env) and the mailer is left
    # unconfigured; runtime.exs never raises.
    test "an unset value is a missing problem and configures no mailer" do
      config = read_prod_config!()

      assert [%{kind: :missing, detail: detail}] = mail_problems(config)
      assert detail =~ "login is by emailed link"
      assert config[:boot_env].verdict == :unconfigured
      assert config[Custyard.Mailer] == nil
    end

    test "an empty value is treated as unset" do
      System.put_env("MAIL_ADAPTER", "")

      config = read_prod_config!()
      assert [%{kind: :missing}] = mail_problems(config)
      assert config[Custyard.Mailer] == nil
    end

    test "an unrecognized value is reported without exposing it" do
      secret = "provider-token-person@example.test\r\nFORGED EVENT"
      System.put_env("MAIL_ADAPTER", secret)

      config = read_prod_config!()

      assert [%{kind: :unsupported, detail: detail}] = mail_problems(config)
      refute inspect(config[:boot_env]) =~ "person@example.test"
      refute inspect(config[:boot_env]) =~ "FORGED EVENT"
      assert config[Custyard.Mailer] == nil

      for adapter <- ~w(mailgun sendgrid smtp postmark lettermint local) do
        assert detail =~ adapter
      end
    end

    test "a recognized value configures its adapter even while its credential is missing" do
      System.put_env("MAIL_ADAPTER", "lettermint")

      config = read_prod_config!()

      assert mail_problems(config) == []
      assert config[Custyard.Mailer][:adapter] == Swoosh.Adapters.Lettermint
      assert config[Custyard.Mailer][:api_token] == nil

      assert Enum.any?(
               config[:boot_env].problems,
               &(&1.variable == "LETTERMINT_PROJECT_TOKEN" and &1.kind == :missing)
             )

      System.put_env("LETTERMINT_PROJECT_TOKEN", "lm_token")
      config = read_prod_config!()
      assert config[Custyard.Mailer][:api_token] == "lm_token"
      refute Enum.any?(config[:boot_env].problems, &(&1.variable == "LETTERMINT_PROJECT_TOKEN"))
    end

    test "local is an explicit opt-in with a warning" do
      System.put_env("MAIL_ADAPTER", "local")

      config = read_prod_config!()

      assert mail_problems(config) == []
      assert config[Custyard.Mailer] == [adapter: Swoosh.Adapters.Local]
      assert config[:email_enabled] == false

      assert Enum.any?(
               config[:boot_env].warnings,
               &(&1.variable == "MAIL_ADAPTER" and &1.detail =~ "discarded")
             )
    end
  end
end

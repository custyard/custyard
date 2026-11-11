defmodule Custyard.Acknowledgments.CredentialRotationTest do
  use Custyard.DataCase, async: false
  import Custyard.Factory
  alias Custyard.{Credentials, Repo}
  alias Custyard.Acknowledgments.{Config, Integration}

  setup do
    previous = Application.get_env(:custyard, :credential_keys)
    old = :crypto.strong_rand_bytes(32)
    current = :crypto.strong_rand_bytes(32)
    Application.put_env(:custyard, :credential_keys, current: old, previous: [])
    tenant = insert_tenant()
    url = "amqp://test-user:test-credential@localhost"
    {:ok, ciphertext} = Credentials.encrypt(url, "acknowledgments.#{tenant.id}.url")

    integration =
      Repo.insert!(%Integration{
        tenant_id: tenant.id,
        source: "test",
        queue: "rotation-test",
        url_ciphertext: ciphertext,
        enabled: false
      })

    Application.put_env(:custyard, :credential_keys, current: current, previous: [old])
    on_exit(fn -> Application.put_env(:custyard, :credential_keys, previous) end)
    %{tenant: tenant, integration: integration, old: old, current: current, url: url}
  end

  test "loading a saved disabled integration rotates it before the previous key is removed", c do
    assert Credentials.stale?(c.integration.url_ciphertext)
    assert Config.load(c.tenant.id)[:url] == c.url
    rotated = Repo.reload!(c.integration)
    refute rotated.url_ciphertext == c.integration.url_ciphertext
    refute Credentials.stale?(rotated.url_ciphertext)
    Application.put_env(:custyard, :credential_keys, current: c.current, previous: [])
    assert Config.load(c.tenant.id)[:url] == c.url
  end

  test "lazy rotation cannot overwrite a credential saved after its read", c do
    changed_url = "amqp://changed-user:changed-credential@localhost"
    {:ok, changed} = Credentials.encrypt(changed_url, "acknowledgments.#{c.tenant.id}.url")
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:custyard, :repo, :query],
        fn _event, _measurements, metadata, _ ->
          if self() == owner and metadata[:source] == "acknowledgment_integrations" and
               String.starts_with?(metadata.query, "SELECT") do
            :telemetry.detach(handler)
            Repo.update!(Ecto.Changeset.change(c.integration, url_ciphertext: changed))
          end
        end,
        nil
      )

    try do
      assert Config.load(c.tenant.id)[:url] == c.url
      assert Repo.reload!(c.integration).url_ciphertext == changed
      assert Config.load(c.tenant.id)[:url] == changed_url
    after
      :telemetry.detach(handler)
    end
  end

  test "unreadable ciphertext remains unavailable and is not rewritten", c do
    Application.put_env(:custyard, :credential_keys, current: c.current, previous: [])
    assert is_nil(Config.load(c.tenant.id)[:url])
    assert Repo.reload!(c.integration).url_ciphertext == c.integration.url_ciphertext
  end
end

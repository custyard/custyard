# Tenant acknowledgment subscriptions

Each tenant owns its acknowledgment subscription, source identity, queue name
and encrypted broker credential. Tenant administrators configure it at
`/app/settings/integrations`; no global source or broker URL supplies tenant
access. Set `CREDENTIAL_ENCRYPTION_KEY` before saving credentials.

The instance operator provisions broker infrastructure. Tenant staff bind
external organization IDs to customers inside their own tenant. Evidence,
bindings, operations and audit events all retain tenant ownership.

## Configuration and lifecycle

Save the source identifier, work queue name, broker URL and enabled state in
the tenant integration form. A blank broker URL retains the saved credential.
Secrets are never rendered back. Source must exactly match incoming evidence.
Each enabled active tenant has its own supervised consumer. Changing the
configuration refreshes that consumer after the settings transaction commits.
Suspension stops its consumer; resumption starts it again.

`ACKNOWLEDGMENTS_PREFETCH` is an installation tuning knob. Retry delays and
operation timeouts are process configuration. Credentials and source identity
remain tenant database settings.

## Credential key rotation

B󠄁r󠄁o󠄁k󠄁e󠄁r󠄁 U󠄁R󠄁L󠄁s󠄁 u󠄁s󠄁e󠄁 t󠄁h󠄁e󠄁 i󠄁n󠄁s󠄁t󠄁a󠄁l󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 c󠄁r󠄁e󠄁d󠄁e󠄁n󠄁t󠄁i󠄁a󠄁l󠄁 e󠄁n󠄁c󠄁r󠄁y󠄁p󠄁t󠄁i󠄁o󠄁n󠄁 k󠄁e󠄁y󠄁s󠄁.󠄁 D󠄁e󠄁p󠄁l󠄁o󠄁y󠄁 t󠄁h󠄁e󠄁 n󠄁e󠄁w󠄁 k󠄁e󠄁y󠄁 a󠄁s󠄁 `CREDENTIAL_ENCRYPTION_KEY` a󠄁n󠄁d󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁 o󠄁l󠄁d󠄁 k󠄁e󠄁y󠄁 a󠄁s󠄁 `CREDENTIAL_ENCRYPTION_KEY_PREVIOUS`.󠄁 L󠄁o󠄁a󠄁d󠄁i󠄁n󠄁g󠄁 a󠄁n󠄁 i󠄁n󠄁t󠄁e󠄁g󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 d󠄁e󠄁c󠄁r󠄁y󠄁p󠄁t󠄁s󠄁 i󠄁t󠄁s󠄁 s󠄁a󠄁v󠄁e󠄁d󠄁 U󠄁R󠄁L󠄁 a󠄁n󠄁d󠄁 r󠄁e󠄁-󠄁e󠄁n󠄁c󠄁r󠄁y󠄁p󠄁t󠄁s󠄁 i󠄁t󠄁 w󠄁i󠄁t󠄁h󠄁 t󠄁h󠄁e󠄁 c󠄁u󠄁r󠄁r󠄁e󠄁n󠄁t󠄁 k󠄁e󠄁y󠄁.󠄁 T󠄁h󠄁e󠄁 u󠄁p󠄁d󠄁a󠄁t󠄁e󠄁 c󠄁o󠄁m󠄁p󠄁a󠄁r󠄁e󠄁s󠄁 t󠄁h󠄁e󠄁 c󠄁i󠄁p󠄁h󠄁e󠄁r󠄁t󠄁e󠄁x󠄁t󠄁 o󠄁r󠄁i󠄁g󠄁i󠄁n󠄁a󠄁l󠄁l󠄁y󠄁 r󠄁e󠄁a󠄁d󠄁,󠄁 s󠄁o󠄁 a󠄁 c󠄁o󠄁n󠄁c󠄁u󠄁r󠄁r󠄁e󠄁n󠄁t󠄁 a󠄁d󠄁m󠄁i󠄁n󠄁i󠄁s󠄁t󠄁r󠄁a󠄁t󠄁o󠄁r󠄁 e󠄁d󠄁i󠄁t󠄁 i󠄁s󠄁 n󠄁e󠄁v󠄁e󠄁r󠄁 o󠄁v󠄁e󠄁r󠄁w󠄁r󠄁i󠄁t󠄁t󠄁e󠄁n󠄁.󠄁 D󠄁i󠄁s󠄁a󠄁b󠄁l󠄁e󠄁d󠄁 i󠄁n󠄁t󠄁e󠄁g󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 a󠄁l󠄁s󠄁o󠄁 n󠄁e󠄁e󠄁d󠄁 t󠄁o󠄁 b󠄁e󠄁 l󠄁o󠄁a󠄁d󠄁e󠄁d󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 r󠄁e󠄁t󠄁i󠄁r󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁v󠄁i󠄁o󠄁u󠄁s󠄁 k󠄁e󠄁y󠄁.󠄁

B󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 r󠄁e󠄁m󠄁o󠄁v󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁v󠄁i󠄁o󠄁u󠄁s󠄁 k󠄁e󠄁y󠄁,󠄁 r󠄁u󠄁n󠄁 t󠄁h󠄁i󠄁s󠄁 d󠄁a󠄁t󠄁a󠄁b󠄁a󠄁s󠄁e󠄁-󠄁o󠄁n󠄁l󠄁y󠄁 v󠄁e󠄁r󠄁i󠄁f󠄁i󠄁c󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 r󠄁e󠄁l󠄁e󠄁a󠄁s󠄁e󠄁 `eval`.󠄁 I󠄁t󠄁 l󠄁o󠄁a󠄁d󠄁s󠄁 e󠄁v󠄁e󠄁r󠄁y󠄁 s󠄁a󠄁v󠄁e󠄁d󠄁 a󠄁c󠄁k󠄁n󠄁o󠄁w󠄁l󠄁e󠄁d󠄁g󠄁m󠄁e󠄁n󠄁t󠄁 i󠄁n󠄁t󠄁e󠄁g󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 t󠄁h󠄁e󠄁n󠄁 r󠄁e󠄁p󠄁o󠄁r󠄁t󠄁s󠄁 c󠄁o󠄁u󠄁n󠄁t󠄁s󠄁 w󠄁i󠄁t󠄁h󠄁o󠄁u󠄁t󠄁 p󠄁r󠄁i󠄁n󠄁t󠄁i󠄁n󠄁g󠄁 b󠄁r󠄁o󠄁k󠄁e󠄁r󠄁 U󠄁R󠄁L󠄁s󠄁 o󠄁r󠄁 c󠄁i󠄁p󠄁h󠄁e󠄁r󠄁t󠄁e󠄁x󠄁t󠄁:󠄁

```elixir
Custyard.Release.with_repo(fn ->
  alias Custyard.{Credentials, Repo}
  alias Custyard.Acknowledgments.{Config, Integration}

  Enum.each(Repo.all(Integration), &Config.load(&1.tenant_id))
  saved = Repo.all(Integration)

  IO.inspect(%{
    previous_key: Enum.count(saved, &Credentials.stale?(&1.url_ciphertext)),
    unreadable: Enum.count(saved, fn integration ->
      match?({:error, _}, Credentials.decrypt(integration.url_ciphertext,
        "acknowledgments.#{integration.tenant_id}.url"))
    end)
  })
end)
```

B󠄁o󠄁t󠄁h󠄁 c󠄁o󠄁u󠄁n󠄁t󠄁s󠄁 m󠄁u󠄁s󠄁t󠄁 b󠄁e󠄁 z󠄁e󠄁r󠄁o󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁v󠄁i󠄁o󠄁u󠄁s󠄁 k󠄁e󠄁y󠄁 i󠄁s󠄁 r󠄁e󠄁m󠄁o󠄁v󠄁e󠄁d󠄁.󠄁 T󠄁h󠄁i󠄁s󠄁 v󠄁e󠄁r󠄁i󠄁f󠄁i󠄁e󠄁s󠄁 a󠄁c󠄁k󠄁n󠄁o󠄁w󠄁l󠄁e󠄁d󠄁g󠄁m󠄁e󠄁n󠄁t󠄁 c󠄁r󠄁e󠄁d󠄁e󠄁n󠄁t󠄁i󠄁a󠄁l󠄁s󠄁 o󠄁n󠄁l󠄁y󠄁:󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁e󠄁v󠄁i󠄁o󠄁u󠄁s󠄁 k󠄁e󠄁y󠄁 u󠄁n󠄁t󠄁i󠄁l󠄁 a󠄁l󠄁l󠄁 o󠄁t󠄁h󠄁e󠄁r󠄁 s󠄁t󠄁o󠄁r󠄁e󠄁d󠄁 c󠄁r󠄁e󠄁d󠄁e󠄁n󠄁t󠄁i󠄁a󠄁l󠄁 t󠄁y󠄁p󠄁e󠄁s󠄁 h󠄁a󠄁v󠄁e󠄁 a󠄁l󠄁s󠄁o󠄁 b󠄁e󠄁e󠄁n󠄁 m󠄁i󠄁g󠄁r󠄁a󠄁t󠄁e󠄁d󠄁.󠄁 A󠄁n󠄁 u󠄁n󠄁r󠄁e󠄁a󠄁d󠄁a󠄁b󠄁l󠄁e󠄁 U󠄁R󠄁L󠄁 s󠄁t󠄁a󠄁y󠄁s󠄁 u󠄁n󠄁a󠄁v󠄁a󠄁i󠄁l󠄁a󠄁b󠄁l󠄁e󠄁 a󠄁n󠄁d󠄁 i󠄁s󠄁 n󠄁e󠄁v󠄁e󠄁r󠄁 r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁d󠄁 w󠄁i󠄁t󠄁h󠄁 a󠄁 n󠄁e󠄁w󠄁 v󠄁a󠄁l󠄁u󠄁e󠄁.󠄁 C󠄁o󠄁r󠄁r󠄁e󠄁c󠄁t󠄁 t󠄁h󠄁e󠄁 s󠄁a󠄁v󠄁e󠄁d󠄁 c󠄁r󠄁e󠄁d󠄁e󠄁n󠄁t󠄁i󠄁a󠄁l󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁l󠄁y󠄁 i󠄁f󠄁 i󠄁t󠄁s󠄁 o󠄁r󠄁i󠄁g󠄁i󠄁n󠄁a󠄁l󠄁 k󠄁e󠄁y󠄁 i󠄁s󠄁 n󠄁o󠄁 l󠄁o󠄁n󠄁g󠄁e󠄁r󠄁 a󠄁v󠄁a󠄁i󠄁l󠄁a󠄁b󠄁l󠄁e󠄁.󠄁

## Broker setup

Use RabbitMQ with persistent storage, quorum queues and the `stream_queue`
feature flag. A dedicated vhost and source-specific credentials establish
source authority; a JSON source field alone does not authenticate a publisher.
Use verified TLS outside the trusted local network:

```
amqps://user:password@broker.example.com:5671/vhost?cacertfile=/etc/ssl/certs/ca-certificates.crt&verify=verify_peer
```

Provision the work queue, delayed retry queues and failure queue before enabling
the subscription. A separate provisioning credential needs configure access.
The runtime credential consumes work, publishes retries/failures/replays and
inspects the failure queue, without configure permission. The producer needs
publish access to its work queue. Store credentials in the tenant integration
form; release commands read that encrypted configuration and never accept or
print broker URLs as command arguments.

Durable messages are acknowledged only after database commit. Retry and replay
transfers require publisher confirmation before the original is acknowledged.
Immutable evidence is idempotent by tenant, source and submission ID. Conflicting
submissions and unmapped organizations remain retained failures rather than
being silently attributed or discarded.

## Organization attribution

Bindings map `(tenant, source, source organization ID)` to one customer in that
tenant. A binding is permanent: it cannot be deleted or reassigned. Repeating
the same binding is harmless. A source organization ID used in another tenant
is independent. Retained acknowledgment evidence prevents customer deletion.

## Operations

The integration page shows connection state, queue counts, retained failures
and bindings. Inspection defaults to a summary; full evidence requires an
explicit action. Replay confirms the oldest retained failure's identity before
transferring it to the work queue. Bind and replay actions are audited with the
tenant and current staff identity. Removed staff, stale sessions, demoted
admins and suspended tenants cannot operate the subscription.

Release commands require an explicit tenant:

```bash
bin/acknowledgments status --tenant 7
bin/acknowledgments provision --tenant 7
bin/acknowledgments bind source.production external-org-id 42 --tenant 7
bin/acknowledgments inspect --tenant 7
bin/acknowledgments inspect --evidence --tenant 7
bin/acknowledgments replay submission-id --tenant 7
```

The CLI starts only the database and required broker clients. Mix tasks expose
the same operations during development. Missing tenant arguments are rejected.

## Validation

```bash
ACKNOWLEDGMENTS_TEST_AMQP_URL=amqp://guest:guest@127.0.0.1:5672 mix test
```

Broker tests use unique queue names and clean them up. Coverage includes durable
transfer, replay identity checks, credential redaction, tenant-specific
configuration, stale administrator rejection and independent subscriptions.

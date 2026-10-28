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

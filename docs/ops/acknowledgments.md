# Operating Colonel acknowledgments

Custyard subscribes to one source-qualified RabbitMQ queue and stores immutable
organization evidence. The consumer is disabled by default. Configure a durable
database and working operator magic-link mail using [the deployment guide](../flyio-deployment.md).

## Broker and configuration

Use RabbitMQ 3.10 or later with persistent broker storage and the `stream_queue`
feature flag enabled. Provision durable quorum queues on a single broker for
the MVP; clustered availability is optional. Quorum queues are used here for
safe at-least-once dead-letter transfer from delayed retries, rather than as a
requirement for a broker cluster.

Each source uses a dedicated vhost and publisher credentials. A privileged
provisioning credential creates queues. OTS can publish to the work queue;
Custyard can consume it and publish retries/failures. Recovery credentials also
read failures and publish replays. Treat vhost access as the trust boundary for
the asserted source and actor: a JSON `source` field is not authentication.
Use TLS for broker traffic outside a trusted local network. Never log the AMQP
URL or commit it to `fly.toml`.

| Environment variable | Value |
| --- | --- |
| `ACKNOWLEDGMENTS_ENABLED` | `false` initially; `true` enables the supervised consumer |
| `ACKNOWLEDGMENTS_AMQP_URL` | Secret broker URI, including the source-specific vhost |
| `ACKNOWLEDGMENTS_SOURCE` | For example `ots.eu.production`; must match every accepted message |
| `ACKNOWLEDGMENTS_QUEUE` | Default `custyard.acknowledgments` |
| `ACKNOWLEDGMENTS_PREFETCH` | Default `1`; integer 1–100 |

One consumer processes sequentially. Prefetch bounds its outstanding deliveries,
not concurrent database writes. Broker interruptions reconnect after five
seconds without repeatedly restarting the application supervisor.

## Provisioning and mappings

Provision before either OTS publication or enabling Custyard's consumer:

```sh
mix acknowledgments.provision
mix acknowledgments.bind ots.eu.production OTS_ORG_EXTID CUSTYARD_ORG_ID
mix acknowledgments.status
```

The numeric Custyard organization ID comes from an existing organization;
the OTS identifier is the organization's public, stable ID. Repeated binding
to the same organization is harmless. Reassignment to another organization is
rejected. Verify mappings before enabling the consumer; no domain or email
guessing occurs. Queue provisioning is idempotent; incompatible existing queue
properties fail visibly and must be resolved without deleting pending work.

Mix is unavailable in production releases. Equivalent release operations are:

```sh
bin/custyard rpc 'Custyard.Acknowledgments.Operations.provision()'
bin/custyard rpc 'Custyard.Acknowledgments.bind("ots.eu.production", "OTS_ORG_EXTID", 123)'
bin/custyard rpc 'Custyard.Acknowledgments.Operations.status()'
```

Provision with a credential allowed to configure queues, then switch to runtime
credentials before enabling the consumer. A Fly deployment can use these same
RPC commands through `fly ssh console`.

## Retry and failure retention

Processing failures retry after 10 seconds, 60 seconds, and 300 seconds. A fourth
failed processing attempt moves the original body to `<queue>.failed`. Each
transfer is persistent and mandatory, and its publisher confirm must succeed
without a return before the original delivery is acknowledged. A failed
transfer closes the subscription, requeues unacknowledged work, and reconnects
after five seconds.

Retry queues `<queue>.retry.1` through `.retry.3` expire their delay and safely
dead-letter to the work queue using quorum at-least-once transfer and
`reject-publish` overflow. Delay expiry transfers work; it does not discard it.
Work/failure queues have no TTL, auto-delete, or delivery limit. Do not apply
operator policies that silently expire, evict, or cap delivery of these queues.
Monitor queue growth, broker disk capacity, and nonempty failure queues.

Failure headers carry attempt count and a sanitized failure category. Original
JSON bytes, timestamp, submission ID, and all evidence remain intact. Routine
logs include safe source/submission identity rather than statement bodies.

Inspect and replay the first retained failure after correcting the cause:

```sh
mix acknowledgments.inspect
mix acknowledgments.replay
```

```sh
bin/custyard rpc 'Custyard.Acknowledgments.Operations.inspect_failure()'
bin/custyard rpc 'Custyard.Acknowledgments.Operations.replay()'
```

Inspection returns the message to the queue. It explicitly exposes the original
evidence, so use an authorized operator terminal. Replay resets delivery attempt
metadata and confirms publication to the work queue before removing the failed
delivery. A conflict cannot be corrected by overwriting evidence; keep it
retained for investigation. Status reports ready-message and consumer counts;
use RabbitMQ's own monitoring for unacknowledged deliveries and queue age.

## Verification

Run all checks with an isolated test broker:

```sh
ACKNOWLEDGMENTS_TEST_AMQP_URL=amqp://test_user:test_password@localhost:5672 mix ci
mix sobelow --exit
mix hex.audit
```

CI supplies a RabbitMQ service so broker integration tests run on every PR.
The tests cover routed confirms, mandatory returns, delayed retries, duplicate
commit, consumer outage and redelivery, failed-message retention, mapping repair,
replay, and organization access/display. Test queues have unique names and are
removed after tests. Never point tests at the production subscription.

Before a production pilot, verify the OTS producer against
[the shared contract](../design/colonel-acknowledgment-contract.md), agree the
statement, and perform these deployment drills:

1. Stop Custyard, submit once from Colonel Admin, and verify `Submitted` with
   queued work. Restart Custyard and verify one organization record.
2. With Custyard stopped, submit and restart the broker using its existing
   persistent storage. Resume Custyard and verify the same evidence arrives.
3. Interrupt the consumer before commit, and again after commit but before
   delivery acknowledgment. Verify recovery yields one record.
4. Restart Custyard and verify exact wording remains visible. Back up the
   database, restore into an isolated instance, and verify the same evidence.
5. Correct a missing organization binding, replay the retained failure, and
   verify the original source/submission identity and evidence.

Only claim the end-to-end Colonel action verified after running the real OTS
producer and agreed production wording. The Custyard implementation and broker
tests do not establish OTS session attribution or its Submitted UI behavior.

# Operating Colonel acknowledgments

Custyard subscribes to one source-qualified RabbitMQ queue and stores immutable
organization evidence. In production the consumer is on by default and starts
once its two secrets are set. Configure a durable database and working operator
magic-link mail using [the deployment guide](../flyio-deployment.md).

## Configuration

| Environment variable | Value |
| --- | --- |
| `ACKNOWLEDGMENTS_ENABLED` | Unset or empty: on in production, off in development and test. `true` or `false` overrides it anywhere; any other value refuses to boot |
| `ACKNOWLEDGMENTS_AMQP_URL` | Secret broker URI, including the source-specific vhost |
| `ACKNOWLEDGMENTS_SOURCE` | For example `ots.eu.production`; must match every accepted message |
| `ACKNOWLEDGMENTS_QUEUE` | Default `custyard.acknowledgments` |
| `ACKNOWLEDGMENTS_PREFETCH` | Default `1`; integer 1 to 100 |

Development and test shells stay off unless `ACKNOWLEDGMENTS_ENABLED=true`, so a
shell holding production broker secrets never consumes the production queue.

On Fly, set the two secrets together:

```sh
fly secrets set -a custyard \
  ACKNOWLEDGMENTS_AMQP_URL='amqps://custyard:<password>@broker.example.com:5671/ots-eu-production?cacertfile=/etc/ssl/certs/ca-certificates.crt&verify=verify_peer' \
  ACKNOWLEDGMENTS_SOURCE=ots.eu.production
```

To keep the URL out of shell history and the process list, read it without
echo and pipe it to `fly secrets import` instead (`printf` is a shell builtin):

```sh
read -rs amqp_url
printf 'ACKNOWLEDGMENTS_AMQP_URL=%s\nACKNOWLEDGMENTS_SOURCE=ots.eu.production\n' "$amqp_url" |
  fly secrets import -a custyard
unset amqp_url
```

To turn the consumer off explicitly, for example while the broker is not yet
provisioned:

```sh
fly secrets set -a custyard ACKNOWLEDGMENTS_ENABLED=false
```

### What happens at boot

The completeness of the configuration is decided when the application starts,
not in runtime configuration, so release commands such as `bin/operator` and
`bin/acknowledgments help` keep working while it is broken.

| State | Result |
| --- | --- |
| Disabled | No consumer. The operator page shows Disabled |
| Enabled, neither URL nor source set | The application starts without a consumer and logs one line naming `ACKNOWLEDGMENTS_AMQP_URL` and `ACKNOWLEDGMENTS_SOURCE`. The operator page shows Not configured and lists the secrets to set |
| Enabled, only one of them set | The application refuses to start; the error names the missing variable |
| Enabled, URL invalid | The application refuses to start; the error names the rule that failed (for example an unparsable URI or a missing host) |
| Enabled and configured | The consumer starts and reconnects every five seconds while the broker is unavailable |

Errors and logs name variables, never their values. In production a plaintext
`amqp` URL to a host other than `localhost`, `*.internal` or `*.flycast` logs a
warning; use TLS for anything else.

## Broker, credentials and TLS

Use RabbitMQ 3.10 or later with persistent broker storage and the `stream_queue`
feature flag enabled. Provision durable quorum queues on a single broker for
the MVP; clustered availability is optional. Quorum queues are used here for
safe at-least-once dead-letter transfer from delayed retries, rather than as a
requirement for a broker cluster.

Each source uses a dedicated vhost and its own credentials. Treat vhost access
as the trust boundary for the asserted source and actor: a JSON `source` field
is not authentication. Never log the AMQP URL or commit it to `fly.toml`.

* OTS publishes to the work queue only.
* Custyard's runtime credential (`ACKNOWLEDGMENTS_AMQP_URL`) consumes the work
  queue, publishes retries, failures and replays through the default exchange,
  and reads `<queue>.failed` for inspect and replay from the operator page and
  `bin/acknowledgments`. It needs no configure permission. For the default queue
  name these permissions have been verified against RabbitMQ 4.2:

  ```sh
  rabbitmqctl set_permissions -p ots-eu-production custyard \
    '^$' \
    '^(amq\.default|custyard\.acknowledgments(\.retry\.[0-9]+|\.failed)?)$' \
    '^custyard\.acknowledgments(\.failed)?$'
  ```

  Write on each queue (not only on the default exchange) is what lets the status
  view count the retry queues.
* A separate provisioning credential declares the queues. Declaring the retry
  queues with a dead-letter target needs configure, write and read on the vhost,
  so give it all three (`'.*' '.*' '.*'`) and use it only for `provision`.

Outside a trusted local network use TLS with certificate verification:

```
amqps://user:password@broker.example.com:5671/vhost?cacertfile=/etc/ssl/certs/ca-certificates.crt&verify=verify_peer
```

The release image ships the system CA bundle at that path. Never use
`verify=verify_none`. Percent-encode a `/` in a vhost name as `%2F`.

## Commands

Erlang distribution is off in the release, so `bin/custyard rpc` and
`bin/custyard remote` do not work. Use the `bin/acknowledgments` release command
instead. It runs beside the server without starting the application, takes the
broker URL and source from the environment only (never as arguments), prints no
URL or credential, and switches from root to the `custyard` user so the SQLite
files keep their owner:

```sh
fly ssh console -a custyard -C "/app/bin/acknowledgments help"
fly ssh console -a custyard -C "/app/bin/acknowledgments status"
fly ssh console -a custyard -C "/app/bin/acknowledgments bind ots.eu.production OTS_ORG_EXTID 123"
fly ssh console -a custyard -C "/app/bin/acknowledgments inspect"
fly ssh console -a custyard -C "/app/bin/acknowledgments replay SUBMISSION_ID"
```

| Command | Purpose |
| --- | --- |
| `status` | Configuration state, then ready and consumer counts for the work, retry and failure queues. One consumer on the work queue means the running server is subscribed |
| `provision` | Declare the work, retry and failure queues; idempotent |
| `bind SOURCE SOURCE_ORG_ID CUSTYARD_ORG_ID` | Attribute a source organization's evidence to a Custyard organization |
| `inspect` | Source, submission ID, failure category and attempt of the oldest failed message |
| `inspect --evidence` | The same, followed by the full original evidence, after a warning line |
| `replay SUBMISSION_ID` | Replay the oldest failed message only while it is still that submission |
| `replay` | Replay the oldest failed message, whatever it is |

Any unknown option, extra argument or missing argument prints usage, changes
nothing and exits 1. In development the same commands run as
`mix acknowledgments.status`, `mix acknowledgments.bind ...` and so on.

## Provisioning and mappings

Provision before either OTS publication or enabling Custyard's consumer. The
running server holds the runtime credential, so supply the provisioning
credential for that one command, without putting it in shell history or a
process list. Either run `mix acknowledgments.provision` from a trusted
workstation with `ACKNOWLEDGMENTS_SOURCE` set and the URL read the same way, or
inside the machine:

```sh
fly ssh console -a custyard
# then, on the machine (nothing is echoed while you paste):
read -rs provision_url
ACKNOWLEDGMENTS_AMQP_URL="$provision_url" /app/bin/acknowledgments provision
unset provision_url
exit
```

Then bind organizations and check the topology with the runtime credential:

```sh
fly ssh console -a custyard -C "/app/bin/acknowledgments bind ots.eu.production OTS_ORG_EXTID 123"
fly ssh console -a custyard -C "/app/bin/acknowledgments status"
```

The numeric Custyard organization ID comes from an existing organization;
the OTS identifier is the organization's public, stable ID. Repeated binding
to the same organization is harmless. A binding is permanent: there is no
delete or reassignment, by design, and reassignment to another organization is
rejected. Verify mappings before enabling the consumer; no domain or email
guessing occurs. Queue provisioning is idempotent; incompatible existing queue
properties fail visibly and must be resolved without deleting pending work.

## Operator page

Super admins operate the subscription at `/operator/acknowledgments` (the
Acknowledgments link in the operator navigation):

* Subscription status (Disabled, Not configured, Connecting or Connected),
  source, queue and prefetch. Not configured lists the secrets to set.
* Ready and consumer counts for every queue, loaded when the page connects and
  on Refresh. Broker errors are short fixed messages.
* The oldest failed message on demand: source, submission ID, failure category
  and attempt only. The evidence itself never reaches the browser; use
  `inspect --evidence` from an authorized terminal for that. A message that
  cannot be identified is shown as unreadable and can only be replayed from the
  command line.
* Replay, after a confirmation, of the message that was inspected. If another
  message has become the oldest since, nothing is replayed and the page asks
  you to inspect again.
* All bindings, and a form to bind an organization of the configured source,
  with a confirmation that names the source, the source organization ID and the
  Custyard organization. Other sources are bound with `bin/acknowledgments bind`.

One broker operation runs at a time per page. Closing the page mid-operation
closes its broker connection and leaves any fetched message in its queue; a
confirmed replay is the exception and completes, with its audit record.
Admins see their organization's bindings, read-only, on the organization's
Acknowledgments tab; an unbound organization receives no evidence until a super
admin binds it.

Every replay attempt and every new binding is recorded in the audit log
(`acknowledgment_replayed`, `acknowledgment_binding_created`) with the operator,
or `cli` or `mix` for commands.

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

Inspect and replay the first retained failure after correcting the cause, from
the operator page or:

```sh
fly ssh console -a custyard -C "/app/bin/acknowledgments inspect"
fly ssh console -a custyard -C "/app/bin/acknowledgments replay SUBMISSION_ID"
```

Inspection leaves the message where it is: it is fetched without
acknowledgement and returns to its position when the operation's channel
closes. `inspect --evidence` exposes the original evidence, so use an authorized
operator terminal. Replay resets delivery attempt metadata and confirms
publication to the work queue before removing the failed delivery. A conflict
cannot be corrected by overwriting evidence; keep it retained for investigation.
Status reports ready-message and consumer counts; use RabbitMQ's own monitoring
for unacknowledged deliveries and queue age.

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
sanitized inspection, guarded replay, connection cleanup when the caller dies,
and organization access/display. Test queues have unique names and are removed
after tests. Never point tests at the production subscription.

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

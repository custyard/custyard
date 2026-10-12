# Colonel acknowledgment message contract

Version 1 is a JSON object containing exactly the fields below. Custyard accepts
the authenticated source's attestation and preserves its evidence; OTS owns the
Colonel session, displayed statement, and explicit human action.

| Field | Requirement |
| --- | --- |
| `schema_version` | Integer `1` |
| `source` | Stable instance and environment identifier matching the subscription's configured source |
| `submission_id` | Stable identifier generated before the first publication; unchanged on retries |
| `organization_id` | Public OTS organization identifier, explicitly mapped in Custyard |
| `actor_id` | Public actor identifier derived from the authenticated OTS session |
| `actor_role` | Role at the time of the action, derived by OTS |
| `actor_type` | Exactly `internal_operator` |
| `statement_key` | Stable identity of the statement |
| `statement_version` | Immutable revision presented to the operator |
| `statement_text` | Exact UTF-8 wording presented, 1–16,384 bytes |
| `statement_hash` | Lowercase hexadecimal SHA-256 of those exact UTF-8 bytes |
| `acknowledged_at` | Original UTC ISO 8601 time; at most 40 bytes; preserved exactly |

Identity fields are nonblank UTF-8 strings of at most 255 bytes, without leading
or trailing whitespace or ASCII control characters. The entire wire body is limited to
65,536 bytes. Unsupported fields require a new schema version. OTS does not
normalize wording or regenerate timestamps, actor details, or IDs on retry.

## Routing and publication

The MVP has one source per Custyard subscription, isolated by RabbitMQ vhost and
credentials. The default queue is `custyard.acknowledgments`; OTS publishes to
the default exchange (`""`) with the configured queue name as routing key.
Provision the topology before enabling publication. It exists independently of
the Custyard process. Dedicated OTS credentials grant publication only to the
source's work queue; the subscriber checks `source` again before persistence.

Publication requires persistent delivery mode, mandatory routing, correlated
publisher confirms, and returned-message handling. An unroutable publication
may still receive a positive confirm: a return always prevents `Submitted`.
Rejection, disconnect, or confirm timeout leaves the attempt unconfirmed and
eligible for retry with the same submission ID. OTS retains that ID and evidence
through the interaction's retry lifecycle. A confirm means broker acceptance,
not Custyard persistence.

OTS's existing generic job publisher is not sufficient as-is: it generates a
fresh message ID per call and does not establish the required routing/confirm
contract. Its acknowledgment producer must explicitly implement this contract.
No local OTS evidence table, outbox, submission API, or return receipt stream is
required by this standalone MVP.

## Persistence and deduplication

Custyard validates the envelope and exact wording hash, resolves the configured
source's organization binding, and commits a dedicated record. It stores its
receipt time separately from `acknowledged_at`. A unique database constraint on
`source` and `submission_id` handles both retries and concurrent inserts. All
evidence fields must match a prior record; different evidence is a retained
failure, never an overwrite. Distinct submission IDs retain distinct actions.

The consumer acknowledges its RabbitMQ delivery only after commit or verified
identical duplication. Corrections and customer-admin consent are outside this
schema. The full wording is carried in each record: Custyard needs no live
document-authoring service or statement lookup during ingestion.

## Production statement

The exact statement key, first version, and wording are an OTS rollout decision.
Custyard's display renders the submitted historical wording without a hardcoded
statement. Test fixtures explicitly use example wording and must not be used as
an approved production attestation.

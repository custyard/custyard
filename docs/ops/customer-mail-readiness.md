# Customer mail readiness

Custyard records replies before attempting delivery. Routine customer email requires both application safeguards and evidence from the deployed installation.

## Implementation scope

1. Persist the authenticated author of replies and internal notes. Audit queueing, retrying, and changes to outbound availability without copying message content into logs.
2. Give tenant administrators an outbound pause independent of inbound forwarding. Recheck it and sender availability before contacting the provider. Keep paused work pending.
3. Persist private drafts per staff member and thread. Keep reply and note drafts separate. Require review when conversation activity changes before sending.
4. Test tenant and customer isolation, portal revocation, staff session revocation, and attachment access. Describe portal credentials as bearer access; contact attribution does not verify identity.
5. Keep hostile HTML and remote images out of message rendering. Quarantine attachments until scanning succeeds; scanner errors fail closed.
6. Run the full test suite and security checks on the integrated code. Review the sending path and migration behavior before deployment.
7. Take a database backup, which includes attachment content, demonstrate restoration in isolation, deploy, and verify production health. Never reset the live database.

## Acceptance evidence

Local tests, production health, provider acceptance, recipient mailbox delivery, and a return to the same thread are separate checks. A green test suite does not prove delivery to an independent mailbox.

The live acceptance run covers support and billing addresses, portal-created requests, From/To/CC review, internal-note privacy, pause/resume, delivery errors and retries, access revocation, and recovery. Do not send customer messages as an automated acceptance test. Use designated test mailboxes with explicit authorization.

Original support mail remains in the source mailbox. Attachment content is stored in the database, so one database backup covers rows and attachments. An installation that still has attachments on disk from an earlier release keeps that directory with the backup until [its import has finished](database.md#upgrading-from-a-release-that-kept-files-on-disk). Restoring a backup must not automatically send old pending replies: start with outbound delivery paused and reconcile provider activity first.

The [backup and restore drill](backup-restore.md) specifies a separate utility
machine, complete-volume recovery and checks that do not start Custyard.

## Validation record, 2026-10-29

The integrated implementation passed 2,731 tests with zero failures, compilation with warnings treated as errors, formatting, strict Credo, Sobelow, dependency vulnerability checks, and Hex retirement/advisory checks. Bandit was upgraded to 1.14.1 for the published HTTP/2 resource-exhaustion advisory.

Independent review found and resolved an open-portal ownership refresh leak, stale-tab draft submission after edits or erasure, acknowledgement of activity absent from the displayed snapshot, and inconsistent malware verdicts across duplicate attachment references. Tenant and installation pauses are checked before provider handoff; an in-flight provider request cannot be recalled.

Recovery snapshot `vs_z4D6D32nnplhqZx8eVa8` was restored into a separate app with a sleep-only entrypoint, no services, no production secrets, and no application workers. SQLite integrity and foreign-key checks passed. Source and restored copies matched: one tenant, one customer, one contact, three threads, ten messages, and one upload with the same manifest hash. There were no email attachments in the pilot snapshot. A separate fixture exercised attachment restoration and rejected a corrupted file.

The private scanner uses a pinned official image, persistent signatures, hourly update checks, finite scan limits, and no public services or public IP addresses. Live benign-content and standard harmless antivirus-test probes returned clean and infected respectively. Scanner availability never bypasses quarantine.

Independent mailbox receipt and a customer's return reply remain external acceptance checks. Local tests and provider status do not establish either outcome.

## Release rehearsal

The exact application image `sha256:9fb6b5057c357d65214b4ce656896cdb76a9ea16130441dd71604d286ca5110c` was loaded on the restored copy with a sleep-only entrypoint. All six pending migrations completed through `20261029023000`. The ten messages were preserved, the personal customer's default contact was backfilled, integrity and foreign keys remained valid, and outbound delivery stayed disabled. No mail workers started.

Scanner health passed after enabling its private IPv4 health-probe listener alongside private IPv6. Its pinned image is `sha256:96ba6697d9a7479baff0a03dedceb96e8c18d28f180fb0ed0046f935e6b90382`. The scanner has no public IPs or public services.

## Production verification

Release 91 runs the rehearsed image on the original single production machine and volume. Both installation and tenant HTTPS health endpoints and login entry points passed. Live SQLite integrity and foreign-key checks passed, all ten existing messages were preserved, and the outbound queue was empty. The personal customer has both an opaque public ID and a default contact.

Production-to-scanner probes returned clean for benign content, infected for the standard harmless antivirus test, and error for an unavailable daemon. The scanner health check passed. Delivery was held disabled during deployment and verification, then resumed. No customer emails were sent by this work, and the existing failed portal reply was not retried automatically.

The temporary restore app, machine, and cloned volume were removed after the successful rehearsal. The source volume and recovery snapshot were retained. The scanner remains a separate private service with two shared CPUs, 4 GiB RAM and a 2 GiB signature volume.

The remaining mailbox acceptance is a fresh support/billing round trip and the portal-reply retry after reviewing From and To. Setup completion requires new delivery and return evidence; previously erased evidence has not been fabricated or replayed.

The dependency update addresses the upstream [Bandit HTTP/2 advisory](https://github.com/mtrudel/bandit/security/advisories/GHSA-pxjf-g536-7r93).

## Deferred product features

Presence indicators, an Undo Send delay, templates, richer search, and reporting can follow the monitored pilot. They do not replace recipient checks, attribution, isolation, or recovery.

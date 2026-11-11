# Tenant baseline pilot cutover

The tenant architecture baseline replaces the pilot database. It is a fresh
installation, with no legacy record conversion or compatibility layer.

The user selected the live pilot as the reset target on 2026-10-28. The verified
target is Fly app `custyard`, machine `d8d0066f561338`, volume
`vol_vwnox10xlzkxp71v`, and SQLite file `/data/custyard.db`. The prior deployment
is release 82 at `1566e28`. `DATABASE_URL` and `DATABASE_PATH` are unset.

## Gates

- Independent integrated tenant-isolation reviews have no unresolved findings.
- Full CI passes 2,630 tests with no failures or skips, including RabbitMQ.
- The production release, assets and disposable-database smoke check pass.
- The final deployment configuration removes obsolete installation-level IMAP
  and notification settings. System authentication mail uses
  `LETTERMINT_PROJECT_TOKEN`; tenant support credentials remain database records.
- The candidate image is built before maintenance begins. Its source revision
  is `882ac24`, including the separate deployment configuration cleanup.

## Procedure

1. Stage the existing system sending token under `LETTERMINT_PROJECT_TOKEN`
   through a direct encrypted CLI pipe. Never print or place its value in command
   arguments. Preserve the credential-encryption and session-signing secrets.
2. Set `INSTANCE_ADMIN_EMAIL` to the explicitly selected installation
   administrator and enable `MAINTENANCE_MODE=true`. Confirm the server and
   background workers have stopped before any database operation.
3. Export a consistent SQLite backup using the prior release's
   `Custyard.Release.export_sqlite/1`, verify its integrity, and snapshot the
   volume. Retain that operational backup outside the active database path.
4. Deploy the candidate image with maintenance still enabled. Use detached
   immediate deployment with smoke checks disabled: maintenance has no HTTP
   listener. Confirm the deployed image revision before replacing the database.
5. Remove only `/data/custyard.db`, `/data/custyard.db-wal` and
   `/data/custyard.db-shm`. Run the new release's migrations and explicit admin
   bootstrap as the `custyard` Unix user. Confirm the new baseline and empty
   tenant/customer/message tables.
6. Disable maintenance and confirm health and installation login. Remove
   obsolete secrets and stop automatic admin recreation after verifying the
   new administrator record. Verify tenant login after registering its hostname.
7. Explicitly provision the OneTimeSecret pilot tenant, its hostname and the
   selected tenant administrator. Configure support mail and integrations as
   tenant records. Existing links and sessions are invalid after the reset.
8. Verify the new tenant's email setup and a provider round trip separately
   from local test evidence.

## Execution record

Completed on 2026-10-28 after explicit selection of the live pilot:

- Confirmed maintenance sleep, no BEAM process, the expected volume mount,
  and no remote database setting before touching the active database.
- Backup: `/data/custyard-before-tenant-baseline-882ac24.db`, integrity `ok`.
- Completed volume snapshot: `vs_jpDmDGyYY9kcjljPa7VD`, five-day retention.
- Baseline deployed under maintenance from `882ac24`, image digest
  `sha256:b086c6785073b004deff3b9a855308c4105b463e159cde4418d6a082ac8ba112`.
- Replaced only the exact active SQLite files; migration `20261028000000`
  installed. Integrity `ok`; foreign-key check returned no violations.
- Explicit installation administrator: `delano@custyard.com`.
- Fresh active tenant: OneTimeSecret, slug `onetimesecret`, host `custyard.com`.
  Verified zero staff, customer, thread, message and email-connection rows.
- Transferred the existing system sending token to `LETTERMINT_PROJECT_TOKEN`
  without logging it. Preserved encryption/signing keys. Removed obsolete
  password, global webhook, old sending-token and base-URL secrets.
- Internal probes initially received 404 without a registered hostname. Fly
  and container probes now send the installation host; independent review
  found no authority gap in that correction.
- Final deployment: Fly release **86**, source `32228e8`, image digest
  `sha256:81569eb86bb37a0154ca76251e2563264bebf5d0f41a51454e48ab5bb91e86af`.
  One running machine; Fly health passing; public health healthy;
  `/admin/login` and `/app/login` return HTTP 200.

## Installation and pilot workspace correction

The initial reset assigned the installation hostname to OneTimeSecret. This was
incorrect: the installation homepage must remain Custyard, and tenant staff use
their own workspace hostname. The user clarified this boundary and explicitly
selected `delano@onetimesecret.com` as the tenant administrator.

The staff administrator was provisioned in the tenant account store. The existing
tenant's host registry entry was changed from `custyard.com` to
`onetimesecret.custyard.com` in one transaction; no tenant data was reset.

The configured installation hostname is now reserved in validation, HTTP
routing, WebSocket host resolution and tenant URL generation. Its homepage
introduces Custyard, offers a workspace-slug finder, and links separately to
installation administration. Tenant homepages and sign-in retain tenant branding.
Independent integrated review found no unresolved issues. Full CI passes
2,638 tests with zero failures or skips; production assets, release and smoke
checks pass.

The certificate for `onetimesecret.custyard.com` is prepared. Public tenant
access still requires DNS, requested from the user because no DNS-management
connection is available here:

| Type | Host | Value |
| --- | --- | --- |
| A | onetimesecret.custyard.com | 66.241.125.114 |
| AAAA | onetimesecret.custyard.com | 2a09:8280:1::ea:321e:0 |

Fresh tenant support-email configuration and the provider round trip remain
pending. No Git push was performed. The installation correction is deployed
from source `4a94fb7`, image digest
`sha256:50fbd245c30e754dfee94cbd32a340a07892c2183dec4bce21a77108715db7d7`.
Validation logs: `/tmp/custyard-ci-installation-host3.log` and
`/tmp/custyard-installation-release-smoke.log`.

Live verification after the correction: Fly release **87** is healthy;
`https://custyard.com/` returns HTTP 200 and renders Custyard with the workspace
finder, verified in a browser. Installation `/app/login` returns 404. On the
live machine, requests with the registered tenant Host header return 200 for
tenant login with OneTimeSecret branding and 404 for installation admin login.
These application checks do not establish public tenant DNS or TLS readiness.

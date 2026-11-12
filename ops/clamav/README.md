# Private ClamAV service

`fly.scanner.toml` runs the official ClamAV image in a separate private Fly app. Custyard streams attachments to it through Fly Proxy on a private Flycast address. Fly Proxy starts the Machine on the first scan connection and stops it once it is idle, so the scanner costs nothing between attachments. It has no public address, receives no Custyard secrets, and mounts only its persistent signature database.

The daemon configuration is injected from `clamd.conf` through Fly's `[[files]]` support. The official image's `/init` starts both ClamD and FreshClam. Its `CLAMD_CONF_*` and `FRESHCLAM_CONF_*` environment mappings are supported, but deployment uses a complete config file to keep limits reviewable in one place. Keep the local daemon socket: `/init` waits for it and FreshClam uses it for reload notification. See the upstream [1.4 Alpine entrypoint](https://github.com/Cisco-Talos/clamav-docker/blob/main/clamav/1.4/alpine/scripts/docker-entrypoint.sh) and [container guide](https://github.com/Cisco-Talos/clamav/blob/main/README.Docker.md).

Use a persistent volume for `/var/lib/clamav`; `_base` images do not bundle signatures. The Machine's command is `start.sh`, also injected through `[[files]]`. It updates the signatures once, blocking, and then runs `/init`. A Machine that was stopped for days therefore never scans with old signatures, and clamd does not refuse to start on `FailIfCvdOlderThan`. While the Machine runs, FreshClam checks for updates 24 times a day. The 4 GiB VM keeps concurrent database reloads enabled; monitor memory during reloads and signature growth. ClamAV recommends [3–4 GiB of memory](https://docs.clamav.net/#recommended-system-requirements) for its standard database.

## Provision and deploy

Run from the repository root. Adapt the app and organization names for another installation. Create the app, the volume and the private address only once:

```sh
fly apps create custyard-scanner --org custyard
fly volumes create clamav_signatures --app custyard-scanner --region ams --size 2
fly ips allocate-v6 --private --app custyard-scanner
fly deploy --config fly.scanner.toml --ha=false --no-public-ips --wait-timeout 20m
fly ips list --app custyard-scanner
```

`fly ips list` must show one private IPv6 address and nothing else. Release any public address it shows. `--no-public-ips` stops `fly deploy` from allocating one for the TCP service.

Before deployment, resolve the selected `1.4_base` image tag and replace the image reference with its immutable digest. Review patch releases and refresh that digest deliberately. Keep one scanner Machine in `ams`. Its only service is raw TCP on port 3310 with `auto_stop_machines = "stop"` and `min_machines_running = 0`. Do not add an `http_service` section, a public IP, or a customer-data volume. All applications on the organization's private network can reach the Flycast address and are within the daemon's trust boundary: ClamD TCP has no authentication. Use a dedicated private network if untrusted applications share the organization.

On the first start, the image downloads signatures to the volume before it opens the scanner port. Allow that initialization to finish. Confirm `fly checks list --app custyard-scanner`, inspect logs for successful updates, and inspect the actual Machine configuration for the single TCP service on 3310 and the intended volume and memory. A TCP check establishes reachability; the acceptance tests below establish scanning behavior.

Configure Custyard with `CLAMAV_HOST=custyard-scanner.flycast`, `CLAMAV_PORT=3310` and `CLAMAV_TIMEOUT_MS=10000`. Do not use `custyard-scanner.internal`: it bypasses Fly Proxy and cannot start a stopped Machine. The application supports private IPv6 endpoints. A scanner outage quarantines attachments while email intake continues.

## Cold start

A stopped Machine needs time to boot, update signatures and load them into clamd. The scan that wakes it times out after `CLAMAV_TIMEOUT_MS` and the attachment stays quarantined. Custyard retries failed scans automatically, so the attachment is released within a few minutes. The [attachment scanning runbook](../../docs/ops/attachment-scanning.md) gives the retry schedule. Fly Proxy stops the Machine again a few minutes after the last scan.

`fly machine list --app custyard-scanner` shows `stopped` while the scanner is idle. A Machine that stays `started` with no attachment traffic means something still connects to it; check for a stray public IP or another application using the address.

### Moving an always-running scanner

An installation deployed before this change has no Flycast address, and Custyard connects to `custyard-scanner.internal`. Switch both apps together:

1. `fly ips allocate-v6 --private --app custyard-scanner`
2. `fly deploy --config fly.scanner.toml --ha=false --no-public-ips --wait-timeout 20m`
3. `fly ips list --app custyard-scanner` shows only the private address.
4. Deploy Custyard with `CLAMAV_HOST=custyard-scanner.flycast` (set in `fly.toml`).

Fly Proxy may stop the scanner a few minutes after step 2. Until step 4 is live, Custyard still uses `.internal`, so scans in that gap fail and are retried after the switch.

## Acceptance and maintenance

From the application Machine, check the protocol against a harmless clean payload and the standard EICAR antivirus test fixture. Verify clean bytes receive a clean verdict, EICAR receives an infected verdict, and scanner unavailability never yields clean. Do not use customer files for the initial probe.

After the application migration, run `Custyard.Release.scan_attachments()` as the Custyard service user. On an installation upgraded from a release that kept attachments on disk, wait until their import into the database has finished. Review verdict counts and verify a clean file downloads, an infected file remains blocked, and a quarantined file has no download or inline image link. The [attachment scanning runbook](../../docs/ops/attachment-scanning.md) describes those application controls.

Alert on failed updates, stale signatures, daemon health failures and memory pressure. `FailIfCvdOlderThan 7` prevents scans against an excessively old database, including after a failed startup update. Keep stream, expansion, recursion and execution limits finite; encrypted containers and limit-exceeded detections remain blocked. Never clear an infected verdict as part of routine maintenance.

Signature data is reproducible from upstream. Keep the volume through ordinary upgrades to avoid repeated full downloads. Customer mail and attachments are stored in the Custyard application database. Neither they nor their backups are ever placed on the scanner.

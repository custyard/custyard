# Private ClamAV service

`fly.scanner.toml` runs the official ClamAV image in a separate private Fly app. The daemon accepts streamed attachments on the organization's IPv6 private network. It has no public service or public address, receives no Custyard secrets, and mounts only its persistent signature database.

The daemon configuration is injected from `clamd.conf` through Fly's `[[files]]` support. The official image's `/init` starts both ClamD and FreshClam. Its `CLAMD_CONF_*` and `FRESHCLAM_CONF_*` environment mappings are supported, but deployment uses a complete config file to keep limits reviewable in one place. Keep the local daemon socket: `/init` waits for it and FreshClam uses it for reload notification. See the upstream [1.4 Alpine entrypoint](https://github.com/Cisco-Talos/clamav-docker/blob/main/clamav/1.4/alpine/scripts/docker-entrypoint.sh) and [container guide](https://github.com/Cisco-Talos/clamav/blob/main/README.Docker.md).

Use a persistent volume for `/var/lib/clamav`; `_base` images do not bundle signatures. FreshClam checks for updates 24 times a day. The 4 GiB VM keeps concurrent database reloads enabled; monitor memory during reloads and signature growth. ClamAV recommends [3–4 GiB of memory](https://docs.clamav.net/#recommended-system-requirements) for its standard database.

## Provision and deploy

Run from the repository root. Adapt the app and organization names for another installation. Create the app and volume only once:

```sh
fly apps create custyard-scanner --org custyard
fly volumes create clamav_signatures --app custyard-scanner --region ams --size 2
fly deploy --config fly.scanner.toml --ha=false --wait-timeout 20m
```

Before deployment, resolve the selected `1.4_base` image tag and replace the image reference with its immutable digest. Review patch releases and refresh that digest deliberately. Retain one always-running scanner Machine in `ams`; this app has no Fly Proxy service or autostart path. Do not add a `services` or `http_service` section, public IP, or customer-data volume. All applications on the shared private network are within the daemon's trust boundary: ClamD TCP has no authentication. Use a dedicated private network if untrusted applications share the organization.

On the first start, the image downloads signatures to the volume before it opens the scanner port. Allow that initialization to finish. Confirm `fly checks list --app custyard-scanner`, inspect logs for successful updates, and inspect the actual Machine configuration for an empty `services` list and the intended volume and memory. A TCP check establishes reachability; the acceptance tests below establish scanning behavior.

Configure Custyard with `CLAMAV_HOST=custyard-scanner.internal`, `CLAMAV_PORT=3310` and `CLAMAV_TIMEOUT_MS=10000`. The application supports private IPv6 endpoints. A scanner outage quarantines attachments while email intake continues.

## Acceptance and maintenance

From the application Machine, check the protocol against a harmless clean payload and the standard EICAR antivirus test fixture. Verify clean bytes receive a clean verdict, EICAR receives an infected verdict, and scanner unavailability never yields clean. Do not use customer files for the initial probe.

After the application migration, run `Custyard.Release.scan_attachments()` as the Custyard service user. Review verdict counts and verify a clean file downloads, an infected file remains blocked, and a quarantined file has no download or inline image link. The [attachment scanning runbook](../../docs/ops/attachment-scanning.md) describes those application controls.

Keep FreshClam running and alert on failed updates, stale signatures, daemon health failures and memory pressure. `FailIfCvdOlderThan 7` prevents continued scans against an excessively old database. Keep stream, expansion, recursion and execution limits finite; encrypted containers and limit-exceeded detections remain blocked. Never clear an infected verdict as part of routine maintenance.

Signature data is reproducible from upstream. Keep the volume through ordinary upgrades to avoid repeated full downloads. Customer mail, the database, attachments and their backups remain exclusively on the Custyard application service.

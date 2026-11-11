# Attachment quarantine and malware scanning

Stored attachments remain quarantined until a configured scanner reports them clean. Fetch completion and scan status are separate: scanner failure does not reject the email or trigger provider redelivery. Pending, infected and failed scans cannot be downloaded or displayed inline. The thread lists the file and its quarantine state.

Existing files start with a pending verdict after migration. Custyard never assumes that an older attachment is clean. There is no manual bypass that marks a file clean without scanning it.

## Configure the scanner

The repository includes a [private Fly deployment configuration and runbook](../../ops/clamav/README.md) with persistent signatures, scanner limits and update settings.

Run a maintained ClamAV daemon on a trusted private endpoint reachable only by the application. Its TCP protocol has no authentication or encryption. Keep signatures updated with `freshclam` and monitor update failures. See the [ClamAV daemon guidance](https://docs.clamav.net/manual/Usage/Scanning.html) and [protocol documentation](https://docs.clamav.net/manual/Usage/ClamdProtocol.html).

Set these installation environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `CLAMAV_HOST` | Trusted private daemon hostname or IP address, IPv4 or IPv6 | Unset: files remain quarantined |
| `CLAMAV_PORT` | Daemon TCP port | `3310` |
| `CLAMAV_TIMEOUT_MS` | Total connection, transfer and result deadline | `10000`; allowed range `100`–`60000` |

The client streams bytes with `INSTREAM`; the daemon needs no access to the attachment volume. The client caps files at 100 MiB, matching the maximum channel attachment limit, bounds daemon replies and treats every unexpected response as failure.

Use explicit daemon settings that prevent incomplete inspections from appearing clean:

```text
StreamMaxLength 100M
MaxFileSize 100M
MaxScanSize 200M
AlertExceedsMax yes
AlertEncrypted yes
FailIfCvdOlderThan 7
```

Keep recursion, scan time and resource limits finite. Encrypted containers and limit-exceeded detections stay blocked. These settings are documented in the upstream [clamd configuration reference](https://github.com/Cisco-Talos/clamav/blob/main/etc/clamd.conf.sample). Review the installed version's settings when provisioning or upgrading the daemon.

## Scan existing files and retry failures

An infected verdict blocks every reference to those same bytes within the tenant, including later duplicates. Infection is terminal: rescanning does not clear it. Suspected false positives require operator investigation; this workflow provides no automatic or user-facing override.

After deploying the migration and configuring the scanner, run as the application service user:

```sh
/app/bin/custyard eval 'IO.inspect(Custyard.Release.scan_attachments())'
```

The release task returns verdict counts only. It checks each file's stored hash before scanning, does not start the web application, and does not print file contents or provider URLs. Existing clean verdicts are withdrawn while a rescan is in progress. A concurrent older scan cannot overwrite a newer verdict.

Tenant administrators can request rescanning for a trusted thread through its attachment controls. A scanner outage leaves files quarantined until an explicit retry succeeds. Confirm clean-file download, a blocked malware test file and blocked downloads during scanner outage before enabling general attachment use.

Quarantine is an application access restriction on files in the private attachment store. Database and attachment-volume backups remain necessary; scans do not replace backup restoration or safe handling of downloaded files.

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

The client streams bytes with `INSTREAM`; the daemon needs no access to the application database, where attachment content is stored. The client caps files at 100 MiB, matching the maximum channel attachment limit, bounds daemon replies and treats every unexpected response as failure.

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

## Automatic retry of failed scans

A scan fails when the scanner does not answer within `CLAMAV_TIMEOUT_MS`. A scanner that scales to zero, as the [private Fly deployment](../../ops/clamav/README.md) does, fails the first scan after it went idle: that scan's connection starts the Machine, which needs 30 to 120 seconds to boot, update its signatures and load them. A provider redelivery does not help, because it reuses attachments that were already fetched and does not scan them again.

Custyard therefore retries failed scans itself. When a scanner is configured, each application instance looks once a minute for attachments whose scan failed and that were stored less than 24 hours ago. An attachment is retried a minute after its failed scan, and after that once the time since its last scan is as long as the attachment was old at that scan. Retries come at about 1, 2, 4, 8 and 16 minutes of age and so on, about 11 in the 24 hours. The schedule counts from when the attachment was stored, so a file the scanner keeps failing stops waking it after a day. Attachments on deleted messages and in suspect threads are not retried. When a retry changes the verdict, open thread views refresh.

Until the 24 hours are over, the thread shows "Quarantined: security scan will be retried". After that it shows "Quarantined: security scan failed", and only a manual rescan, described below, scans the file again. A retry that fails again leaves the file quarantined. The log records `attachment_scan_retry_completed` with verdict counts after a pass that rescanned something, and `attachment_scan_retry_failed` when a pass could not run.

## Scan existing files and retry failures

An infected verdict blocks every reference to those same bytes within the tenant, including later duplicates. Infection is terminal: rescanning does not clear it. Suspected false positives require operator investigation; this workflow provides no automatic or user-facing override.

After deploying the migration and configuring the scanner, run as the application service user:

```sh
/app/bin/custyard eval 'IO.inspect(Custyard.Release.scan_attachments())'
```

The release task returns verdict counts only. It reads each file back from the database and checks its size and SHA-256 before scanning, does not start the web application, and does not print file contents or provider URLs. Content that is missing, over 100 MiB or no longer the bytes that were stored gets an error verdict and stays quarantined. Existing clean verdicts are withdrawn while a rescan is in progress. A concurrent older scan cannot overwrite a newer verdict.

On an installation upgraded from a release that kept attachments on disk, run a rescan only after the import reports nothing pending ([database operations](database.md#upgrading-from-a-release-that-kept-files-on-disk)). The import itself leaves verdicts as they were, but a rescan of an attachment that is not in the database yet ends in an error verdict, which quarantines it until a later rescan succeeds.

Tenant administrators can request rescanning for a trusted thread through its attachment controls. A scanner outage that lasts longer than the automatic retry leaves files quarantined until an explicit rescan succeeds. Confirm clean-file download, a blocked malware test file and blocked downloads during scanner outage before enabling general attachment use.

Quarantine is an application access restriction on attachment content, which is stored in the application database. Database backups, which include that content, remain necessary; scans do not replace backup restoration or safe handling of downloaded files.

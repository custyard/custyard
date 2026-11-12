#!/bin/sh
# Custyard scanner start command (fly.scanner.toml [processes]).
#
# The Machine stops when idle, so it can wake with signatures that are days
# old. Update them once, blocking, before clamd loads: scans never run on a
# stale database, and clamd does not refuse to start on FailIfCvdOlderThan.
# A failed update still starts clamd, which then applies FailIfCvdOlderThan.
set -u

# Mirror the image's initial download: no clamd to notify yet, and clamd
# loading the database next is the test.
sed -e 's|^\(TestDatabases \)|#\1|' \
	-e '$a TestDatabases no' \
	-e 's|^\(NotifyClamd \)|#\1|' \
	/etc/clamav/freshclam.conf > /tmp/freshclam-start.conf
timeout 300 freshclam --foreground --stdout --config-file=/tmp/freshclam-start.conf ||
	echo "Startup signature update failed; starting clamd with the current database"
rm -f /tmp/freshclam-start.conf

# The image's /init runs a given command with CLAMAV_NO_CLAMD=true. This
# script is that command; start the daemons as /init does without one.
export CLAMAV_NO_CLAMD=false
exec /init

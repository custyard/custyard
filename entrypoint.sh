#!/bin/bash
set -e

# MAINTENANCE_MODE=true keeps the machine running for `fly ssh` but does not
# start the app, so nothing writes the database (moving it to Turso,
# docs/ops/database.md).
if [ "${MAINTENANCE_MODE:-}" = "true" ]; then
    echo "MAINTENANCE_MODE is true: Custyard is not started. Unset it to start."
    exec sleep infinity
fi

# Everything else happens inside the one VM boot: config/runtime.exs parses
# the environment without raising, and Custyard.Application either starts the
# app (probing the database, running migrations and creating the first
# instance administrator) or serves a doctor page saying what to fix
# (docs/backlog/1103-first-run-experience.md). `bin/doctor` prints the same
# report from a shell.
exec "$@"

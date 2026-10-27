#!/bin/bash
set -e

# MAINTENANCE_MODE=true keeps the machine running for `fly ssh` but starts
# neither migrations nor the app, so nothing writes the database (moving it
# to Turso, docs/ops/database.md).
if [ "${MAINTENANCE_MODE:-}" = "true" ]; then
    echo "MAINTENANCE_MODE is true: Custyard is not started. Unset it to start."
    exec sleep infinity
fi

# Require SECRET_KEY_BASE in production
# Auto-generating causes session/LiveView invalidation on every restart (Fly.io auto_stop_machines)
if [ -z "$SECRET_KEY_BASE" ]; then
    echo "ERROR: SECRET_KEY_BASE is not set."
    echo ""
    echo "This is required for session security and LiveView connections."
    echo "Generate a key and set it as a persistent secret:"
    echo ""
    echo "  # For Fly.io:"
    echo "  fly secrets set SECRET_KEY_BASE=\$(mix phx.gen.secret)"
    echo ""
    echo "  # For Docker/local:"
    echo "  export SECRET_KEY_BASE=\$(openssl rand -hex 64)"
    echo ""
    echo "Without a persistent key, all sessions and LiveView connections"
    echo "will be invalidated on every container restart."
    exit 1
fi

# LIVE_VIEW_SIGNING_SALT: optional, derived from SECRET_KEY_BASE in runtime.exs if not set
# Only set this if you need a different salt than the derived default

# Run migrations, then the operator bootstrap: when OPERATOR_EMAIL is set,
# create that super_admin if it does not exist yet (never modifying an
# existing account). One eval, so the VM boots once; neither step starts the
# application. An invalid OPERATOR_EMAIL exits nonzero and fails the boot.
echo "Running database migrations and operator bootstrap..."
bin/custyard eval "Custyard.Release.migrate(); Custyard.Release.bootstrap_operator()"

echo "Custyard ready. Starting server..."
exec "$@"

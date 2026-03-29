#!/bin/bash
set -e

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

# Run migrations
echo "Running database migrations..."
bin/custyard eval "Custyard.Release.migrate()"

# Create operator account if it doesn't exist (email-only auth, no password needed)
bin/custyard eval "Custyard.Release.setup_operator()"

echo "Custyard ready. Starting server..."
exec "$@"

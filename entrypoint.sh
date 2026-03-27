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

# Generate or load operator password
if [ -z "$OPERATOR_PASSWORD" ]; then
    export OPERATOR_PASSWORD=$(openssl rand -base64 12)

    # Only print password if explicitly opted in (avoid leaking to centralized logs)
    if [ "$PRINT_OPERATOR_PASSWORD" = "true" ]; then
        echo ""
        echo "=========================================="
        echo "OPERATOR PASSWORD (auto-generated):"
        echo "  $OPERATOR_PASSWORD"
        echo "=========================================="
        echo ""
    else
        echo "Auto-generated OPERATOR_PASSWORD (set PRINT_OPERATOR_PASSWORD=true to display, or set OPERATOR_PASSWORD env to use a fixed value)"
    fi
fi

# Create/update operator account (reads OPERATOR_PASSWORD from env)
bin/custyard eval "Custyard.Release.setup_operator()"

echo "Custyard ready. Starting server..."
exec "$@"

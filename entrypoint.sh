#!/bin/bash
set -e

# Generate secret key if not set
if [ -z "$SECRET_KEY_BASE" ]; then
    export SECRET_KEY_BASE=$(openssl rand -hex 64)
    echo "Generated SECRET_KEY_BASE (auto-generated, set SECRET_KEY_BASE env to use a fixed value)"
fi

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

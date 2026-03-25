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
    OPERATOR_PASSWORD=$(openssl rand -base64 12)
    echo ""
    echo "=========================================="
    echo "OPERATOR PASSWORD (auto-generated):"
    echo "  $OPERATOR_PASSWORD"
    echo ""
    echo "Set OPERATOR_PASSWORD env to suppress this message."
    echo "=========================================="
    echo ""
fi

# Create/update operator account
bin/custyard eval "Custyard.Release.setup_operator(\"$OPERATOR_PASSWORD\")"

echo "Custyard ready. Starting server..."
exec "$@"

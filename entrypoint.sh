#!/bin/bash
set -e

# Generate secret key if not set
if [ -z "$SECRET_KEY_BASE" ]; then
    export SECRET_KEY_BASE=$(openssl rand -hex 64)
    echo "Generated SECRET_KEY_BASE"
fi

# Run migrations
bin/custyard eval "Custyard.Release.migrate()"

# Generate or load operator password
if [ -z "$OPERATOR_PASSWORD" ]; then
    OPERATOR_PASSWORD=$(openssl rand -base64 12)
    echo ""
    echo "=========================================="
    echo "OPERATOR PASSWORD: $OPERATOR_PASSWORD"
    echo "=========================================="
    echo ""
fi

# Create/update operator account
bin/custyard eval "Custyard.Release.setup_operator(\"$OPERATOR_PASSWORD\")"

exec "$@"

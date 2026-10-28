# Development Guide

## Quick Start

```bash
# Install dependencies
mix setup

# Start all services
overmind start -f Procfile.dev
```

The app runs at http://localhost:4000

## Process Management

### Overmind (Recommended)

```bash
# Start all processes
overmind start -f Procfile.dev

# Connect to Phoenix IEx shell
overmind connect web

# Restart a single process
overmind restart web

# Stop all
overmind stop
```

### Manual Start

```bash
# Single command (watchers run in-process)
iex -S mix phx.server
```

## Environment Variables

### Email Ingestion (Optional)

The LMTP server is disabled by default. Enable it with environment variables. IMAP mailboxes are connected per channel in the staff UI (see below).

#### LMTP Server

Receives email directly from an MTA (Postfix, Stalwart, Maddy).

```bash
LMTP_ENABLED=true          # Enable LMTP server
LMTP_PORT=2024             # Listen port (default: 2024)
LMTP_HOSTNAME=localhost    # Hostname in greeting

# TLS (optional, for direct exposure without reverse proxy)
LMTP_TLS_CERTFILE=/path/to/cert.pem
LMTP_TLS_KEYFILE=/path/to/key.pem
LMTP_TLS_CACERTFILE=/path/to/ca.pem
```

Test with swaks:
```bash
swaks --to support@custyard.test \
      --from sender@example.com \
      --server localhost:2024 \
      --protocol LMTP
```

See [docs/lmtp-troubleshooting.md](lmtp-troubleshooting.md) for debugging.

#### IMAP channels

An IMAP mailbox is a channel: create it on the organization page (Channels,
New channel, "Read a mailbox over IMAP"). Development encrypts the stored
password with a fixed key from `config/dev.exs` and allows a local test server
(`localhost` or an IP) through `:imap_allow_private_hosts`. Production needs
`CREDENTIAL_ENCRYPTION_KEY`. See [docs/ops/inbound-channels.md](ops/inbound-channels.md).
The old `IMAP_*` variables are gone, and `IMAP_ENABLED=true` stops the app at boot.

### Outbound Email (Production)

```bash
MAIL_ADAPTER=mailgun|sendgrid|smtp

# Mailgun
MAILGUN_API_KEY=key-xxx
MAILGUN_DOMAIN=mg.example.com

# SendGrid
SENDGRID_API_KEY=SG.xxx

# SMTP
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=user
SMTP_PASSWORD=secret
SMTP_SSL=false
```

In development, emails are captured by `Swoosh.Adapters.Local` and viewable at http://localhost:4000/dev/mailbox

## Dev-Only Features

### Contact Impersonation

In development, append `?as=<contact_id>` to any URL to view as that contact:

```
http://localhost:4000/conversations?as=123
```

This bypasses authentication for testing. Controlled by `allow_contact_impersonation: true` in `config/dev.exs`.

### LiveDashboard

Available at http://localhost:4000/dev/dashboard

### Dev Routes

Additional routes available only in dev:
- `/dev/mailbox` - Captured emails
- `/dev/dashboard` - LiveDashboard

## Database

SQLite database at `priv/repo/custyard_dev.db`.

```bash
# Create and migrate
mix ecto.setup

# Reset (drop, create, migrate, seed)
mix ecto.reset

# Run migrations only
mix ecto.migrate

# Generate a migration
mix ecto.gen.migration add_foo_to_bar
```

### Seeds

`priv/repo/seeds.exs` creates sample data. Re-run with:
```bash
mix run priv/repo/seeds.exs
```

## Testing

```bash
# All tests
mix test

# Email infrastructure tests
mix test test/custyard/email/

# Specific file
mix test test/custyard/email/lmtp_server_test.exs

# With coverage
mix test --cover
```

### Test Database

Tests use `priv/repo/custyard_test.db` with `Ecto.Adapters.SQL.Sandbox` for isolation.

## Code Quality

```bash
# Format check
mix format --check-formatted

# Compile with warnings as errors
mix compile --warnings-as-errors

# All CI checks
mix ci
```

## Assets

Tailwind and esbuild are managed by Mix:

```bash
# Install asset tools
mix tailwind.install
mix esbuild.install

# Build once
mix assets.build

# Deploy build (minified)
mix assets.deploy
```

In development, watchers run automatically via the Procfile or Phoenix endpoint config.

## Troubleshooting

### Port Already in Use

```bash
# Find what's using port 4000
lsof -i :4000

# Kill it
kill -9 <PID>
```

### Database Locked

SQLite can lock if multiple writers conflict:

```bash
# Reset the database
rm priv/repo/custyard_dev.db
mix ecto.setup
```

### LMTP Connection Refused

1. Check `LMTP_ENABLED=true` is set
2. Check port isn't blocked: `nc -zv localhost 2024`
3. Check logs for startup errors

### Assets Not Updating

```bash
# Clear build cache
rm -rf _build/dev/lib/custyard/.mix/
mix assets.build
```

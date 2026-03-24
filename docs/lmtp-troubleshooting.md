# LMTP Troubleshooting Guide

This guide covers common LMTP server issues, diagnostic commands, and log interpretation.

## Quick Diagnostics

### Check if LMTP server is running

```bash
# Check if the port is listening (default: 2024)
nc -zv localhost 2024

# Or with netstat
netstat -an | grep 2024
```

### Basic connectivity test with swaks

```bash
# Simple test - send to local LMTP server
swaks --to support@example.com \
      --from sender@example.com \
      --server localhost:2024 \
      --protocol lmtp

# With verbose output for debugging
swaks --to support@example.com \
      --from sender@example.com \
      --server localhost:2024 \
      --protocol lmtp \
      --show-all
```

### Test with raw TCP

```bash
# Connect and interact manually
telnet localhost 2024
```

Expected sequence:
```
220 localhost Custyard LMTP server ready
LHLO test.local
250-localhost
250-PIPELINING
250 SIZE 10485760
MAIL FROM:<sender@example.com>
250 OK
RCPT TO:<support@example.com>
250 OK
DATA
354 Start mail input
Subject: Test
From: sender@example.com

Test body
.
250 2.0.0 Message accepted
QUIT
221 Bye
```

## Common Issues

### Connection Refused

**Symptom**: `Connection refused` when connecting to LMTP port

**Causes and solutions**:

1. **LMTP server not enabled**
   ```bash
   # Check environment variable
   echo $LMTP_ENABLED

   # Enable in environment
   export LMTP_ENABLED=true
   ```

2. **Wrong port**
   ```bash
   # Check configured port (default: 2024)
   echo $LMTP_PORT

   # Test correct port
   nc -zv localhost $LMTP_PORT
   ```

3. **Application not started**
   ```bash
   # Check if Elixir app is running
   ps aux | grep beam

   # Check application logs for startup errors
   tail -f log/dev.log
   ```

4. **Port already in use**
   ```bash
   # Find what's using the port
   lsof -i :2024

   # Use different port
   export LMTP_PORT=2025
   ```

5. **Firewall blocking**
   ```bash
   # Check iptables (Linux)
   iptables -L -n | grep 2024

   # Check ufw (Ubuntu)
   ufw status
   ```

### Authentication Errors

**Symptom**: `503 AUTH not supported` response

**Explanation**: The LMTP server does not support AUTH. This is expected behavior - LMTP is designed for local mail transfer from trusted MTAs, not for end-user authentication.

**Solution**: Configure your MTA (Postfix, etc.) to relay mail to LMTP without requiring authentication:

```
# Postfix main.cf example
lmtp_sasl_auth_enable = no
```

### Parse Failures

**Symptom**: `550 5.7.0 Permanent failure: {:parse_failed, ...}` in logs

**Common causes**:

1. **Missing required headers**
   - Ensure `From:` header is present
   - Ensure `To:` header is present
   - Check for valid `Message-ID` header

2. **Invalid MIME structure**
   ```bash
   # Validate email structure
   cat email.eml | formail -c
   ```

3. **Charset issues**
   - Supported: UTF-8, ISO-8859-1, Windows-1252
   - Check Content-Type charset declaration matches actual encoding

4. **Transfer encoding problems**
   - Supported: 7bit, 8bit, base64, quoted-printable
   - Base64 content must not have invalid characters

**Debugging parse failures**:

```elixir
# In IEx console
raw_email = File.read!("problem_email.eml")
Custyard.Email.Parser.parse(raw_email)
```

### Rate Limit Exceeded

**Symptom**: `421 4.7.1 Too many messages on this connection` or `421 4.7.1 Server busy, try again later`

**Explanation**: The server enforces rate limits to protect against abuse.

**Check current limits**:

```bash
# Environment variables (if set)
echo "Per-connection: ${LMTP_MESSAGES_PER_CONNECTION:-100}"
echo "Per-minute: ${LMTP_MESSAGES_PER_MINUTE:-1000}"
```

**Default limits**:
- 100 messages per connection
- 1000 messages per minute globally

**Solutions**:

1. **Reduce sending rate** - space out messages
2. **Increase limits** (in config/runtime.exs):
   ```elixir
   config :custyard, :lmtp,
     rate_limit: [
       messages_per_connection: 200,
       messages_per_minute: 2000
     ]
   ```
3. **Check for retry loops** in sending MTA

### Mail Loop Detected

**Symptom**: `554 5.4.6 Mail loop detected`

**Explanation**: The server detected its hostname appearing too many times in Received headers, indicating a forwarding loop.

**Default threshold**: 3 occurrences

**Diagnosis**:

```bash
# Check Received headers in problematic email
grep -i "^Received:" problem_email.eml | head -10
```

Look for repeated occurrences of your server's hostname.

**Solutions**:

1. **Fix routing configuration** - ensure mail isn't being forwarded back
2. **Check MX records** - verify correct destination
3. **Increase threshold** (if legitimate):
   ```elixir
   config :custyard, :lmtp,
     max_received_count: 5
   ```

### Message Too Large

**Symptom**: `552 5.3.4 Message size exceeds fixed maximum message size`

**Default limit**: 10 MB (10,485,760 bytes)

**Check message size**:

```bash
wc -c < email.eml
```

**Solutions**:

1. **Reduce message/attachment size**
2. **Increase limit**:
   ```elixir
   config :custyard, :lmtp,
     max_message_size: 25_000_000  # 25 MB
   ```

### Too Many Recipients

**Symptom**: `452 4.5.3 Too many recipients`

**Default limit**: 100 recipients per message

**Solutions**:

1. **Split into multiple messages**
2. **Increase limit**:
   ```elixir
   config :custyard, :lmtp,
     max_recipients: 250
   ```

### TLS/STARTTLS Issues

**Symptom**: STARTTLS not advertised or TLS handshake fails

**Check STARTTLS is configured**:

```bash
# Test EHLO/LHLO response for STARTTLS
swaks --to test@example.com \
      --server localhost:2024 \
      --protocol lmtp \
      --quit-after EHLO
```

**Required environment variables**:

```bash
export LMTP_TLS_CERTFILE=/path/to/cert.pem
export LMTP_TLS_KEYFILE=/path/to/key.pem
```

**Verify certificate files**:

```bash
# Check certificate
openssl x509 -in /path/to/cert.pem -text -noout

# Check key matches certificate
openssl rsa -in /path/to/key.pem -check -noout
```

**Common TLS errors**:

1. **Certificate expired**: Renew certificates
2. **Key mismatch**: Ensure key corresponds to certificate
3. **Permission denied**: Ensure app can read cert/key files

## Log Interpretation

### Enabling Debug Logging

```elixir
# In config/dev.exs or config/runtime.exs
config :logger, level: :debug
```

### Common Log Entries

**Successful connection**:
```
[debug] LMTP EHLO from client.example.com
[debug] LMTP MAIL FROM: sender@example.com
[debug] LMTP RCPT TO: support@example.com
[debug] LMTP DATA received from sender@example.com to ["support@example.com"], size: 1234
[info] LMTP event event=[:custyard, :lmtp, :email, :stop] result=:ok
```

**Rate limit hit**:
```
[warning] LMTP rate limit exceeded: per-connection limit reached
```

**Parse error**:
```
[warning] LMTP permanent error: {:parse_failed, %RuntimeError{message: "invalid header"}}
```

**Loop detection**:
```
[warning] LMTP mail loop detected: hostname mail.example.com found 3 times in Received headers
```

### Telemetry Events

Attach handlers to monitor LMTP activity:

```elixir
# In application.ex or a monitoring module
:telemetry.attach_many(
  "lmtp-monitor",
  [
    [:custyard, :lmtp, :connection, :open],
    [:custyard, :lmtp, :connection, :close],
    [:custyard, :lmtp, :email, :start],
    [:custyard, :lmtp, :email, :stop],
    [:custyard, :lmtp, :rate_limit, :exceeded]
  ],
  fn event, measurements, metadata, _config ->
    Logger.info("LMTP telemetry",
      event: inspect(event),
      measurements: inspect(measurements),
      metadata: inspect(metadata)
    )
  end,
  nil
)
```

## Testing Tools

### swaks (Swiss Army Knife for SMTP)

Install:
```bash
# macOS
brew install swaks

# Debian/Ubuntu
apt install swaks

# RHEL/CentOS
yum install swaks
```

Common test scenarios:

```bash
# Basic test
swaks --to support@example.com --server localhost:2024 --protocol lmtp

# Test with attachment
swaks --to support@example.com --server localhost:2024 --protocol lmtp \
      --attach /path/to/file.pdf

# Test multipart HTML/text
swaks --to support@example.com --server localhost:2024 --protocol lmtp \
      --body "Plain text body" \
      --add-header "Content-Type: multipart/alternative"

# Test with custom headers
swaks --to support@example.com --server localhost:2024 --protocol lmtp \
      --header "X-Customer-Tier: enterprise" \
      --header "X-Priority: 1"

# Test large message (check size limits)
dd if=/dev/zero bs=1M count=5 | base64 > /tmp/large.txt
swaks --to support@example.com --server localhost:2024 --protocol lmtp \
      --attach /tmp/large.txt

# Test threading headers
swaks --to support@example.com --server localhost:2024 --protocol lmtp \
      --header "In-Reply-To: <original-msg-id@example.com>" \
      --header "References: <original-msg-id@example.com>"
```

### IEx debugging

```elixir
# Connect to running application
iex --sname debug --remsh custyard@hostname

# Or in development
iex -S mix

# Test parser directly
raw = File.read!("test/fixtures/emails/simple_plain_text.eml")
{:ok, parsed} = Custyard.Email.Parser.parse(raw)
IO.inspect(parsed, label: "Parsed email")

# Check LMTP server status
:ranch.info()
```

### Postfix integration testing

If using Postfix as the MTA:

```bash
# Check Postfix is configured to relay to LMTP
postconf | grep lmtp

# Test mail flow
echo "Test body" | mail -s "Test subject" support@example.com

# Check Postfix mail queue
mailq

# View Postfix logs
tail -f /var/log/mail.log
```

## Configuration Reference

Full LMTP configuration options:

```elixir
config :custyard, :lmtp,
  enabled: true,                    # Enable LMTP server
  port: 2024,                       # Listen port
  hostname: "mail.example.com",     # Server hostname (used in loop detection)
  max_connections: 1024,            # Max concurrent connections
  num_acceptors: 10,                # Number of acceptor processes
  max_message_size: 10_485_760,     # Max message size in bytes (10 MB)
  max_recipients: 100,              # Max recipients per message
  max_received_count: 3,            # Loop detection threshold
  tls: [                            # TLS options (optional)
    certfile: "/path/to/cert.pem",
    keyfile: "/path/to/key.pem",
    cacertfile: "/path/to/ca.pem"   # Optional: for client verification
  ],
  rate_limit: [
    messages_per_connection: 100,   # Per-connection limit
    messages_per_minute: 1000,      # Global rate limit
    window_seconds: 60              # Rate limit window
  ]
```

Environment variables (for production):

```bash
LMTP_ENABLED=true
LMTP_PORT=2024
LMTP_HOSTNAME=mail.example.com
LMTP_TLS_CERTFILE=/path/to/cert.pem
LMTP_TLS_KEYFILE=/path/to/key.pem
```

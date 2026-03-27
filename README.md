# Custyard

Customer support platform with email ingestion via LMTP/IMAP.

## Setup

```bash
mix setup
overmind start -f Procfile.dev
```

mix compile && mix fly.secrets 


http://localhost:4000

## Phoenix.new / Remote VM Setup

### GitHub Auth (Device Flow)

```bash
gh auth login
```

Select:
1. `GitHub.com`
2. `HTTPS`
3. `Yes` (authenticate git)
4. `Login with a web browser`

Copy the one-time code, then on your local machine:

https://github.com/login/device

Paste code, authorize. VM session completes automatically.

```bash
gh auth setup-git
```

### Clone Private Repo

```bash
git clone https://github.com/owner/private-repo.git
```

## Docs

- [Development Guide](docs/development.md)
- [LMTP Troubleshooting](docs/lmtp-troubleshooting.md)
- [Email Test Strategy](docs/qa/email-test-strategy.md)

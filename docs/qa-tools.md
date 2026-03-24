# QA Tools for Phoenix/Elixir Projects

For a scrappy project with real customers, focus on tools that catch real bugs without slowing iteration. Here's a pragmatic stack:

## Immediate Value (add these now)

### 1. mix.exs dependencies

```elixir
defp deps do
  [
    # ... existing deps
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
  ]
end
```

| Tool | Purpose | Why Now |
|------|---------|---------|
| Credo | Style + complexity warnings | Catches real issues, configurable strictness |
| Dialyxir | Type checking via Dialyzer | Finds bugs before customers do |
| Sobelow | Security scanner | Essential with customer data |

### 2. .credo.exs (relaxed for velocity)

```elixir
%{
  configs: [
    %{
      name: "default",
      strict: false,
      checks: %{
        disabled: [
          # Re-enable as you stabilize
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
```

### 3. Simple git hook (.githooks/pre-push)

```bash
#!/bin/bash
set -e

echo "Running pre-push checks..."

# Fast checks only - don't block flow
mix format --check-formatted
mix compile --warnings-as-errors

echo "Checks passed."
```

Enable with:
```bash
git config core.hooksPath .githooks
```

### 4. GitHub Actions (.github/workflows/ci.yml)

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  MIX_ENV: test
  ELIXIR_VERSION: "1.18.3"
  OTP_VERSION: "27.2.4"

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-

      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix format --check-formatted
      - run: mix test
      - run: mix credo --strict

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}
      - run: mix deps.get
      - run: mix sobelow --config
```

## Add Later (when you stabilize)

| Tool | When | Why Wait |
|------|------|----------|
| Dialyzer in CI | After core architecture settles | PLT builds are slow, specs take time |
| ExCoveralls | When you have test discipline | Coverage metrics need baseline |
| Doctor | Before v1.0 | Doc coverage enforcement |
| Boundary | Multi-context apps | Enforces module boundaries |

## Skip Entirely

- **pre-commit hooks that run tests** — too slow, breaks flow
- **Husky/lint-staged** — overkill for Elixir (mix format is fast)
- **Complex multi-job CI matrices** — one Elixir version is fine for now
- **Mandatory PR reviews** — you're small, ship fast

## Quick Setup Commands

```bash
# Add deps
mix deps.get

# Generate default configs
mix credo gen.config
mix sobelow --config

# Create hooks dir
mkdir -p .githooks
cat > .githooks/pre-push << 'EOF'
#!/bin/bash
set -e
mix format --check-formatted
mix compile --warnings-as-errors
EOF
chmod +x .githooks/pre-push
git config core.hooksPath .githooks

# First run (generates PLT, takes a few minutes)
mix dialyzer --plt
```

The goal: catch bugs that would embarrass you in front of customers, without slowing down the iteration pace that's getting you customer feedback.

# docs/lessons-learned/03-supervision-tree.md
---

# What is the supervision tree?

The supervision tree uses the `:one_for_one` strategy under `Custyard.Supervisor`.

## Core children (always started)

1.  `CustyardWeb.Telemetry` - metrics/instrumentation
2.  `Custyard.Repo` - Ecto database connection pool
3.  `DNSCluster` - cluster discovery (ignored in dev)
4.  `Phoenix.PubSub` - pub/sub for LiveView and channels
5.  `Finch` - HTTP client pool
6.  `CustyardWeb.Endpoint` - Phoenix web server

## Conditionally added

*   `Custyard.Scoring.Scheduler` - if `:start_scheduler` config is true (default)
*   `Custyard.Email.LMTPServer` - if `lmtp.enabled` is true
*   `Custyard.Email.ImapPoller` - if `imap.enabled` is true

## Dev-only post-startup

A non-supervised `Task` creates/resets the dev operator account (`admin@custyard.local`) with a random password, logged to the console.

Conditional processes are controlled via `config/config.exs` or `config/dev.exs`. LMTP and IMAP are disabled by default.

## Elixir or Phoenix?

Elixir (inherited from Erlang/OTP). Supervision trees are a core OTP pattern for fault tolerance. Supervisors monitor and restart child processes based on a defined strategy when they crash.

Phoenix uses this pattern like any other Elixir application. `Application` behavior and `Supervisor` are part of Elixir's standard library, built on Erlang's `:supervisor` behavior.

Phoenix-specific parts here are `CustyardWeb.Endpoint` and `CustyardWeb.Telemetry`. The rest (`Repo`, `PubSub`, `Finch`, custom LMTP/IMAP processes) are standard Elixir/OTP children usable in any Elixir app.

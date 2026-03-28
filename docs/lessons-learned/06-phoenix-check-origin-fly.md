Phoenix check_origin behind Fly.io proxy:

WebSocket origin validation failed despite trying four different
approaches: MFA tuple, function capture, :conn atom, socket-level vs
endpoint-level placement. All rejected connections with the same error.

Root causes identified:

1. MFA Arity Mismatch

Phoenix calls `apply(module, function, [uri | arguments])`. With MFA
`{Mod, :check_origin?, []}`, the call becomes `check_origin?(uri)` —
arity 1. If your function is defined as `check_origin?(uri, opts)` —
arity 2 — it crashes with UndefinedFunctionError, not a clean false.

Fix: pass an empty list as the second arg: `{Mod, :check_origin?, [[]]}`
Or add a defensive arity-1 clause: `def check_origin?(uri), do: check_origin?(uri, [])`

2. Scheme Mismatch (Fly.io / any TLS-terminating proxy)

The :conn check compares `uri.scheme == Atom.to_string(conn.scheme)`.
Fly terminates TLS at its proxy and forwards HTTP internally:

  - Origin header from browser: https://myapp.fly.dev
  - conn.scheme after proxy: :http
  - "https" == "http" → always false

Fix: trust the forwarded headers with Plug.RewriteOn in endpoint.ex:
```elixir
plug Plug.RewriteOn, [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]
```

And/or add force_ssl in prod.exs (compile-time config required):
```elixir
force_ssl: [rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]]
```

3. ETS Caching

Phoenix caches check_origin config in ETS after the first WebSocket
connection via `Phoenix.Config.cache/3`. Changes to Application env
don't take effect without a process restart. This explains why config
changes appeared to have no effect — the cached value persisted.

Diagnosis approach:

When origin validation mysteriously fails, add logging at three levels:
- Startup: confirm check_origin config type (MFA vs list vs :conn)
- Endpoint plug: log Origin header as it arrives from proxy
- Validator callback: log the URI struct received and primary_host

Key insight: "Phoenix isn't calling our validator" was the critical
observation. The validator was either crashing (arity) or never being
reached (wrong config type cached). Tracing the actual invocation path
in Phoenix.Socket.Transport revealed the MFA dispatch mechanics.

References:
- Phoenix.Endpoint docs: hexdocs.pm/phoenix/Phoenix.Endpoint.html
- Phoenix source: deps/phoenix/lib/phoenix/socket/transport.ex (check_origin_config, origin_allowed?)
- Fly.io community: "Phoenix LiveView constantly refreshes with custom domain"

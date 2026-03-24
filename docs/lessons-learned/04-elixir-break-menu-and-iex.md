# docs/lessons-learned/04-elixir-break-menu-and-iex.md
---

# Elixir BREAK Menu and IEx

## The BREAK menu (Ctrl+C twice)

When running `mix phx.server`, Ctrl+C shows an interactive menu instead of exiting:

| Key | Action |
|-----|--------|
| `a` | Abort (exit) |
| `c` | Continue (resume if Ctrl+C was accidental) |
| `p` | Proc info - debug hung processes |
| `i` | System info - memory, process count |
| `D` | ETS tables with memory usage |
| `k` | Kill a specific process |

## Disabling for process managers

With Overmind/Foreman, the menu blocks clean shutdown. Disable it:

```procfile
# Procfile.dev
web: elixir --erl "+Bd" -S mix phx.server
```

Or set globally:

```bash
export ELIXIR_ERL_OPTIONS="+Bd"
```

## IEx vs plain mix

`mix phx.server` - runs app, logs only, no interaction.

`iex -S mix phx.server` - runs app with live REPL attached:

```elixir
Repo.all(User)                      # query db
MyApp.Accounts.get_user(1)          # call functions
r MyAppWeb.UserController           # recompile module
:sys.get_state(pid)                 # inspect process state
```

For debugging, add to code:

```elixir
require IEx; IEx.pry()
```

Execution pauses, REPL inspects local scope.

## When to use what

| Scenario | Command |
|----------|---------|
| Quick server run | `mix phx.server` |
| Interactive debugging | `iex -S mix phx.server` |
| Overmind/Foreman | `elixir --erl "+Bd" -S mix phx.server` |
| Production | Mix releases (no BREAK menu) |

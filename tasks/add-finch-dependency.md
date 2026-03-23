# Add Missing Finch Dependency

## Issue
The application supervisor references `Finch` but it's not listed in `mix.exs` dependencies.

## Location
- `lib/custyard/application.ex:13` - uses `{Finch, name: Custyard.Finch}`
- `mix.exs` - missing `{:finch, "~> 0.18"}` in deps

## Error
```
** (ArgumentError) The module Finch was given as a child to a supervisor but it does not exist
```

## Fix
Add to `mix.exs` deps:
```elixir
{:finch, "~> 0.18"},
```

Then run:
```bash
mix deps.get
```

# docs/lessons-learned/01-erlang-atoms.md
---
# The `String.to_existing_atom/1` Pattern

`String.to_existing_atom/1` (and `String.to_atom/1`) convert a string into an Erlang atom. Atoms are never garbage collected; there's a fixed limit (default ~1 million). If user-controlled input flows into these functions, an attacker can send arbitrary strings to create new atoms until the VM crashes with an out-of-memory error.

Let's examine where this occurs in the codebase:

```elixir
Search(pattern: "String\.to_existing_atom|String\.to_atom", path: "/Users/d/Projects/experiments/custyard/lib")
  ⎿ Found 11 lines
    lib/custyard/settings.ex:59:    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
    lib/custyard/settings.ex:75:      {String.to_existing_atom(tier), {warning, critical}}
    lib/custyard_web/live/operator/projects_live.ex:75:    field_atom = String.to_existing_atom(field)
    lib/custyard_web/live/operator/settings_live.ex:87:      |> Enum.map(fn {tier, [w, c]} -> {String.to_atom(tier), {w, c}} end)
    lib/custyard_web/live/operator/organizations_live.ex:73:    field_atom = String.to_existing_atom(field)
    lib/custyard_web/live/operator/organizations_live.ex:111:      tier: String.to_existing_atom(form_data.tier),
    lib/custyard/email/sieve_header_mapper.ex:97:      {:ok, atom_value} -> {String.to_existing_atom(property), atom_value}
    lib/custyard/email/sieve_header_mapper.ex:111:    {:ok, String.to_existing_atom(value)}
    lib/custyard/email/sieve_header_mapper.ex:115:    {:ok, String.to_existing_atom(value)}
    lib/custyard_web/live/operator/conversation_live.ex:133:    new_state = String.to_existing_atom(state)
    lib/custyard_web/live/portal/new_request_live.ex:30:        urgency: String.to_existing_atom(params["urgency"]),
```

The pattern appears in two main contexts:

1.  **Direct user input (dangerous):** In LiveView event handlers where form parameters are directly passed:
    *   `conversation_live.ex:133`: The `state` parameter from buttons like "Waiting on customer" / "Mark resolved".
    *   `new_request_live.ex:30`: The urgency dropdown value.
    *   `organizations_live.ex:73,111`: Form field names and the `tier` value.
    *   `projects_live.ex:75`: Form field names.
    *   `settings_live.ex:87`: Threshold tier keys from form data.

2.  **Email-sourced input (also dangerous):** `sieve_header_mapper.ex` converts email header values to atoms. A crafted inbound email with arbitrary header values could create new atoms.

The fix in each case is straightforward: validate against an allowlist of known, permitted values instead of converting blindly. For example:

```elixir
# Instead of:
new_state = String.to_existing_atom(state)

# Do this:
new_state = case state do
  "active" -> :active
  "waiting" -> :waiting
  "resolved" -> :resolved
  _ -> raise "invalid state"
end
```

The `to_existing_atom` variant is slightly safer than `to_atom` as it only succeeds if the atom already exists. However, it still crashes with an `ArgumentError` on unknown input rather than handling it gracefully. Therefore, it remains both a denial-of-service (DoS) and a crash vector.

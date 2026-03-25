Plug vs LiveView mount for portal auth:

A Plug runs in the HTTP request pipeline before the LiveView mounts. It
operates on the conn struct and can halt the request early (return 404,
redirect, etc.). Error handling is via standard Phoenix error views.

LiveView on_mount runs after the HTTP request succeeds but before the
LiveView renders. It operates on the socket and can redirect or halt
mounting. Errors here crash the LiveView process (showing the LiveView
error UI, not Phoenix error pages).

Current state:
- PortalAuth plug exists, validates org token, assigns :current_org to
  conn — but it's never called
- Each portal LiveView calls Helpers.get_organization(params, socket)
  in mount, duplicating the lookup
- Helpers.get_organization uses Repo.get_by! which raises on invalid
  tokens, crashing the LiveView

Implications of each approach:

┌─────────────────────┬────────────────────────────────────────────────┬───────────────────────────────────────────────────┐
│       Aspect        │              Wire PortalAuth Plug              │               Keep per-mount logic                │
├─────────────────────┼────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
│ Invalid token       │ Clean 404 page (plug halts, error view         │ LiveView crash/reconnect loop (current behavior)  │
│ handling            │ renders)                                       │                                                   │
├─────────────────────┼────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
│ DB queries          │ One lookup in plug, org available in socket    │ One lookup per LiveView mount                     │
│                     │ via session                                    │                                                   │
├─────────────────────┼────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
│ Error consistency   │ Standard Phoenix error pages                   │ LiveView error UI (inconsistent with non-LiveView │
│                     │                                                │  routes)                                          │
├─────────────────────┼────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
│ Custom domain       │ Plug already handles both token and custom     │ Each LiveView must remember to use Helpers        │
│ support             │ domain paths                                   │                                                   │
└─────────────────────┴────────────────────────────────────────────────┴───────────────────────────────────────────────────┘

Recommendation: Wire the plug. It centralizes auth, fixes the
crash-on-invalid-token bug (task 155), reduces duplicate lookups, and
gives consistent error handling. The LiveViews then just read
socket.assigns.current_org (passed from plug → session → LiveView
connect_info).

The tradeoff: slightly more indirection (org flows through session rather
than being fetched directly). But this is the standard Phoenix pattern
for authenticated routes.

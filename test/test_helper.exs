# SQLite only allows one writer at a time. Run tests sequentially
# to avoid "Database busy" errors from write contention.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Custyard.Repo, :manual)

# SQLite only allows one writer at a time. Run tests sequentially
# to avoid "Database busy" errors from write contention.
{:ok, _pid} = Custyard.Attachments.StubClient.start_link()
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Custyard.Repo, :manual)

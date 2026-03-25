# test_helper.exs is loaded before any test files run.
# It's the place to configure the test environment.

# Start ExUnit — the built-in test framework
ExUnit.start()

# Start Ecto's SQL Sandbox.
# The sandbox wraps each test in a database transaction that gets rolled back
# when the test finishes. This means tests don't interfere with each other
# and the database is always clean.
Ecto.Adapters.SQL.Sandbox.mode(CmAqi.Repo, :manual)

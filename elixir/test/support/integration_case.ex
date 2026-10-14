# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiFedi.IntegrationCase do
  @moduledoc """
  Support for integration tests running against a live docker-compose.test.yml
  stack.

  Expected services (see docker-compose.test.yml):
    * Postgres on localhost:15432 (database: sukhi_fedi_test)
    * NATS on localhost:14222 (plain core — no streams to create)
    * Bun fedify NATS Micro service connected to the above NATS

  Bring up the stack:

      docker compose -f docker-compose.test.yml up -d

  Run integration tests:

      mix test --only integration

  The default `mix test` excludes the `:integration` tag so unit tests stay
  hermetic.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import SukhiFedi.IntegrationCase
      alias SukhiFedi.Repo
    end
  end

  setup tags do
    # Use a sandbox checkout when the Repo is started (it is when
    # `mix test --only integration` runs without `--no-start`). Falls
    # back to a no-op if the sandbox is not in use, so tests that don't
    # touch the DB still work.
    case Process.whereis(SukhiFedi.Repo) do
      nil ->
        :ok

      _pid ->
        :ok = checkout_with_retry()
        unless tags[:async], do: Ecto.Adapters.SQL.Sandbox.mode(SukhiFedi.Repo, {:shared, self()})
    end

    bypass = Bypass.open()

    {:ok,
     mock_remote: bypass,
     mock_remote_url: "http://localhost:#{bypass.port}"}
  end

  # On PGlite every pooled connection shares one backend session, so one
  # client's open sandbox transaction shows up as "already a transaction
  # running" to the next test's BEGIN. It clears within a few ms; retry
  # briefly. Real Postgres (a session per connection) never hits it.
  defp checkout_with_retry(attempts \\ 20) do
    Ecto.Adapters.SQL.Sandbox.checkout(SukhiFedi.Repo)
  catch
    :exit, _ when attempts > 1 ->
      Process.sleep(25)
      checkout_with_retry(attempts - 1)
  end

  @doc """
  Build the URL of a mock remote actor's inbox. Useful when writing
  delivery tests.
  """
  def mock_remote_inbox_url(bypass, actor \\ "mockuser") do
    "http://localhost:#{bypass.port}/users/#{actor}/inbox"
  end
end

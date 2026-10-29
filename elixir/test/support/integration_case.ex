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
    if Process.whereis(SukhiFedi.Repo) do
      if SukhiFedi.Store.datalevin?(), do: wipe_datalevin(), else: sandbox_checkout(tags)
    end

    # Sandbox rows roll back; the emoji cache must not remember them.
    SukhiFedi.CustomEmojis.clear_cache()

    bypass = Bypass.open()

    {:ok,
     mock_remote: bypass,
     mock_remote_url: "http://localhost:#{bypass.port}"}
  end

  # The Datalevin store has no sandbox: every test starts from an empty database.
  defp wipe_datalevin, do: SukhiFedi.Datalevin.Admin.wipe!()

  defp sandbox_checkout(tags) do
    :ok = checkout_with_retry()
    unless tags[:async], do: Ecto.Adapters.SQL.Sandbox.mode(SukhiFedi.Repo, {:shared, self()})
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
  Value for `@tag skip:` / `@moduletag skip:` on tests that write to S3.
  `scripts/test-pglite.sh` sets SKIP_S3_TESTS=1 (PGlite alone has no S3);
  everywhere else this is `false` and the test runs.

  (A tag + `--exclude` can't do this: `--only integration` includes these
  tests, and in ExUnit an include beats an exclude.)
  """
  def s3_skip do
    if System.get_env("SKIP_S3_TESTS") == "1", do: "needs S3 (not on PGlite)", else: false
  end

  @doc """
  Build the URL of a mock remote actor's inbox. Useful when writing
  delivery tests.
  """
  def mock_remote_inbox_url(bypass, actor \\ "mockuser") do
    "http://localhost:#{bypass.port}/users/#{actor}/inbox"
  end
end

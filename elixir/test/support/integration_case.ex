# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiFedi.IntegrationCase do
  @moduledoc """
  Support for integration tests running against a live docker-compose.test.yml
  stack.

  The business data is Datalevin: it needs the `dtlv` binary and a directory
  to open (`DATALEVIN_DIR`). The job queue is PostgreSQL.

  Expected services (see docker-compose.test.yml):
    * Postgres on localhost:15432 (database: sukhi_fedi_test), for the queue
    * NATS on localhost:14222 (plain core — no streams to create)
    * Bun fedify NATS Micro service connected to the above NATS

  Bring up the stack:

      docker compose -f docker-compose.test.yml up -d

  Run integration tests (`make test-pgrust` does all of this without Docker):

      DATALEVIN_DIR=$(mktemp -d) DATALEVIN_DURABILITY=nosync mix test --only integration

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

  setup do
    # The stores have no sandbox: every test starts from an empty database, an
    # empty job queue and empty account tables.
    if Process.whereis(SukhiFedi.Repo), do: wipe()

    # The store was just emptied; the emoji cache must not remember it.
    SukhiFedi.CustomEmojis.clear_cache()

    bypass = Bypass.open()

    {:ok,
     mock_remote: bypass,
     mock_remote_url: "http://localhost:#{bypass.port}"}
  end

  defp wipe do
    SukhiFedi.Store.Hosi.wipe!()
    SukhiFedi.QueueRepo.delete_all("oban_jobs")

    # The accounts' tables: CASCADE reaches every table that points at
    # `accounts`; the ones that point at nothing are named.
    # Ids go on from test to test: the rate limits remember accounts by id.
    SukhiFedi.AccountRepo.query!("""
    TRUNCATE accounts, join_applications, outbox, admin_audits,
             suspension_notices, suspension_pending, suspension_evidence, suspension_cutoffs
    CASCADE
    """)
  end

  @doc """
  Value for `@tag skip:` / `@moduletag skip:` on tests that write to S3.
  `scripts/test-pgrust.sh` sets SKIP_S3_TESTS=1 (pgrust alone has no S3);
  everywhere else this is `false` and the test runs.

  (A tag + `--exclude` can't do this: `--only integration` includes these
  tests, and in ExUnit an include beats an exclude.)
  """
  def s3_skip do
    if System.get_env("SKIP_S3_TESTS") == "1", do: "needs S3 (not on pgrust)", else: false
  end

  @doc """
  Writes an account row. The tests make their accounts here, so that where
  accounts are kept is said in one place.
  """
  def insert_account!(account), do: SukhiFedi.AccountRepo.insert!(account)

  @doc """
  Build the URL of a mock remote actor's inbox. Useful when writing
  delivery tests.
  """
  def mock_remote_inbox_url(bypass, actor \\ "mockuser") do
    "http://localhost:#{bypass.port}/users/#{actor}/inbox"
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.QueueRepo do
  @moduledoc """
  The PostgreSQL connection for the job queues: Oban's `oban_jobs` (shared with
  `SukhiDelivery.QueueRepo`, disjoint queues) and the `raw_blobs` table of
  `SukhiFedi.RawStore.Postgres`.

  This is all PostgreSQL is for. The business data is in Datalevin
  (`SukhiFedi.Repo`); see `SukhiFedi.Queue`.
  """

  use Ecto.Repo, otp_app: :sukhi_fedi, adapter: Ecto.Adapters.Postgres
end

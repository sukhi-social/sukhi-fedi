# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.PruneWorker do
  @moduledoc "Trims `pull_log` (see `Log.prune/1`). Runs from Oban's cron plugin."

  use Oban.Worker, queue: :federation, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    SukhiDelivery.PullFederation.Log.prune()
    :ok
  end
end

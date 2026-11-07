# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.JoinApplications.Sweeper do
  @moduledoc """
  Deletes applications nobody confirmed receiving the mail for
  (`JoinApplications.purge_unconfirmed/1`: three hours). Cron runs it every ten minutes.
  """

  use Oban.Worker, queue: :publish, max_attempts: 1

  alias SukhiFedi.JoinApplications

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = JoinApplications.purge_unconfirmed()
    :ok
  end
end

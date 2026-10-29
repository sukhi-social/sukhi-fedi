# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountDeletion.Worker do
  @moduledoc """
  Drives `SukhiFedi.AccountDeletion`. Cron runs it every ten minutes: it
  takes the requests whose day is up, and for each does steps until the
  account is closed (a bounded number of steps per run; the next run
  carries on from the saved state — `started_at` — where this one stopped).
  """

  use Oban.Worker, queue: :publish, max_attempts: 3

  alias SukhiFedi.AccountDeletion

  # A step deletes up to one batch of notes; this bounds one run on a small box.
  @steps_per_run 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(AccountDeletion.due(), &drive(&1, @steps_per_run))
    :ok
  end

  defp drive(_d, 0), do: :ok

  defp drive(d, left) do
    case AccountDeletion.finish_step(d) do
      :more -> drive(d, left - 1)
      _ -> :ok
    end
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.Notifier do
  @moduledoc """
  Tells pull-capable hosts that something new is waiting, and does it
  *once per quiet window per host*, not once per activity.

  `schedule/1` inserts one `NotifyWorker` job per host, delayed by
  `quiet_s/0`; an Oban uniqueness rule (one pending job per host) makes
  every further activity inside that window a no-op insert. When the job
  runs it reads the log's current state, so the one notification it sends
  covers everything appended meanwhile. A burst of 100 posts is one
  notification per host, not 100.
  """

  alias SukhiDelivery.PullFederation.NotifyWorker

  @quiet_s 1

  @doc "Seconds a notification waits so that a burst is coalesced into one."
  def quiet_s, do: Application.get_env(:sukhi_delivery, :pull_notify_quiet_s, @quiet_s)

  @spec schedule([String.t()]) :: :ok
  def schedule(hosts) when is_list(hosts) do
    Enum.each(hosts, fn host ->
      %{"host" => host}
      |> NotifyWorker.new(schedule_in: quiet_s())
      |> then(&Oban.insert(SukhiDelivery.Oban, &1))
    end)
  end
end

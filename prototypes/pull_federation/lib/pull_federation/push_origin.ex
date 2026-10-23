# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.PushOrigin do
  @moduledoc """
  The push model, for comparison. Pure state machine like `Origin`.

  One job per (activity, target domain); each job is one signed POST.
  Failure handling copies the Mastodon shape from
  `/mnt/project-files/federation/push-federation-ste.md` §6:
  `n^4 + 15` seconds between tries plus jitter up to `0.5 * n^4`, and a
  hard stop after `max_attempts`. Jitter is a hash, so runs are
  deterministic.
  """

  defstruct jobs: [], max_attempts: 16, sent: 0, failed: 0, dropped: 0

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc "Queue one job per target domain; first try is due at `now`."
  def publish(%__MODULE__{} = o, activity, targets, now) do
    new_jobs = for t <- targets, do: %{activity: activity, target: t, attempt: 1, due: now}
    %{o | jobs: o.jobs ++ new_jobs}
  end

  @doc "Jobs whose time has come: `{origin, jobs}`. They leave the queue until `result/4`."
  def due(%__MODULE__{} = o, now) do
    {ready, rest} = Enum.split_with(o.jobs, &(&1.due <= now))
    {%{o | jobs: rest, sent: o.sent + length(ready)}, ready}
  end

  @doc "`:ok` is final; `:fail` reschedules with backoff or drops at the cap."
  def result(%__MODULE__{} = o, _job, :ok, _now), do: o

  def result(%__MODULE__{max_attempts: max} = o, %{attempt: n}, :fail, _now) when n >= max do
    %{o | failed: o.failed + 1, dropped: o.dropped + 1}
  end

  def result(%__MODULE__{} = o, %{attempt: n} = job, :fail, now) do
    base = Integer.pow(n, 4)
    jitter = :erlang.phash2({job.activity.id, n}, div(base, 2) + 1)
    delay = (base + 15 + jitter) * 1_000
    retry = %{job | attempt: n + 1, due: now + delay}
    %{o | jobs: [retry | o.jobs], failed: o.failed + 1}
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule MnesiaQueue do
  @moduledoc """
  A durable delivery-job queue on Mnesia: the parts of Oban that the delivery
  node actually uses, and nothing else.

  Every state change is one `:mnesia.transaction/1`, so the properties live
  here and only here:

    * atomic claim: a job is handed to exactly one claimer;
    * per-host concurrency cap, enforced inside the claim transaction;
    * exponential backoff, `max_attempts`, then `:dead` (kept for inspection);
    * unique keys: enqueueing a live duplicate returns `{:duplicate, id}`;
    * lifeline: a claim carries a lease, and `lifeline/1` returns expired
      claims to the ready set (so a crashed worker loses nothing);
    * prune: terminal jobs are deleted after a retention period.

  Time is always passed in (`now`, ms), as in the other prototypes, so tests
  are deterministic.

  Tables
  ------
    * `:mq_jobs`    set          — every live or recently-terminal job
    * `:mq_ready`   ordered_set  — `{run_at, id}` of claimable jobs
    * `:mq_hosts`   set          — `{host, running_count}`
    * `:mq_unique`  set          — `{unique_key, id}` for live jobs
    * `:mq_ids`     set          — id counter (gaps after aborts are fine)

  The outbox-to-queue hop is at-least-once: enqueue after the domain commit,
  and de-duplicate delivery by `delivery_receipts` (see the evaluation doc).
  """

  @jobs :mq_jobs
  @ready :mq_ready
  @hosts :mq_hosts
  @unique :mq_unique

  @type id :: pos_integer()
  @type job :: %{
          id: id,
          host: String.t(),
          state: :ready | :claimed | :completed | :dead,
          run_at: integer,
          attempt: non_neg_integer,
          max_attempts: pos_integer,
          lease_until: integer | nil,
          unique_key: term | nil,
          payload: term,
          inserted_at: integer,
          finished_at: integer | nil,
          last_error: term | nil
        }

  @max_backoff_ms 6 * 60 * 60 * 1000

  # ---------------------------------------------------------------- setup

  @doc """
  Create the tables. `storage` is `:ram_copies` or `:disc_copies`; the latter
  needs a schema (`:mnesia.create_schema/1`) created before Mnesia starts.
  """
  def setup(storage \\ :ram_copies) when storage in [:ram_copies, :disc_copies] do
    :ok = :mnesia.start() |> ok()
    node = [node()]
    opts = [{storage, node}]

    create(@jobs, [attributes: [:id, :job], type: :set] ++ opts)
    create(@ready, [attributes: [:key, :id], type: :ordered_set] ++ opts)
    create(@hosts, [attributes: [:host, :running], type: :set] ++ opts)
    create(@unique, [attributes: [:key, :id], type: :set] ++ opts)
    create(:mq_ids, [attributes: [:key, :val], type: :set] ++ opts)
    :ok = :mnesia.wait_for_tables([@jobs, @ready, @hosts, @unique, :mq_ids], 30_000)
    :ok
  end

  def stop, do: :mnesia.stop()

  defp ok(:ok), do: :ok
  defp ok({:error, {:already_started, _}}), do: :ok

  defp create(name, opts) do
    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
    end
  end

  # -------------------------------------------------------------- enqueue

  @doc """
  Insert a job. Options: `:run_at` (default `now`), `:max_attempts` (default 10),
  `:unique_key`. Returns `{:ok, id}` or `{:duplicate, existing_id}`.
  """
  @spec enqueue(String.t(), term, integer, keyword) :: {:ok, id} | {:duplicate, id}
  def enqueue(host, payload, now, opts \\ []) do
    unique_key = Keyword.get(opts, :unique_key)

    tx(fn ->
      case unique_key && :mnesia.read(@unique, unique_key) do
        [{@unique, _, existing}] ->
          {:duplicate, existing}

        _ ->
          id = :mnesia.dirty_update_counter(:mq_ids, :id, 1)
          job = %{
            id: id,
            host: host,
            state: :ready,
            run_at: Keyword.get(opts, :run_at, now),
            attempt: 0,
            max_attempts: Keyword.get(opts, :max_attempts, 10),
            lease_until: nil,
            unique_key: unique_key,
            payload: payload,
            inserted_at: now,
            finished_at: nil,
            last_error: nil
          }

          put_ready(job)
          if unique_key, do: :mnesia.write({@unique, unique_key, id})
          {:ok, id}
      end
    end)
  end

  # ---------------------------------------------------------------- claim

  @doc """
  Atomically claim up to `limit` due jobs, skipping hosts that already have
  `host_limit` jobs running. The scan looks at most `scan` ready entries.
  Returns the claimed jobs.
  """
  @spec claim(integer, pos_integer, keyword) :: [job]
  def claim(now, lease_ms, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1)
    host_limit = Keyword.get(opts, :host_limit, 4)
    scan = Keyword.get(opts, :scan, 500)

    tx(fn ->
      {claimed, _seen} = scan_ready(:mnesia.first(@ready), now, lease_ms, host_limit, limit, scan, [], %{})
      Enum.reverse(claimed)
    end)
  end

  defp scan_ready(:"$end_of_table", _, _, _, _, _, acc, seen), do: {acc, seen}
  defp scan_ready(_, _, _, _, limit, _, acc, seen) when length(acc) >= limit, do: {acc, seen}
  defp scan_ready(_, _, _, _, _, 0, acc, seen), do: {acc, seen}

  defp scan_ready({run_at, _id} = key, now, lease_ms, host_limit, limit, scan, acc, seen) do
    if run_at > now do
      # ordered by run_at: nothing further is due
      {acc, seen}
    else
      [{@ready, ^key, id}] = :mnesia.read(@ready, key)
      [{@jobs, ^id, job}] = :mnesia.read(@jobs, id)
      running = Map.get_lazy(seen, job.host, fn -> running(job.host) end)
      next = :mnesia.next(@ready, key)

      if running >= host_limit do
        scan_ready(next, now, lease_ms, host_limit, limit, scan - 1, acc, Map.put(seen, job.host, running))
      else
        job = %{job | state: :claimed, attempt: job.attempt + 1, lease_until: now + lease_ms}
        :mnesia.write({@jobs, id, job})
        :mnesia.delete({@ready, key})
        :mnesia.write({@hosts, job.host, running + 1})
        scan_ready(next, now, lease_ms, host_limit, limit, scan - 1, [job | acc], Map.put(seen, job.host, running + 1))
      end
    end
  end

  defp running(host) do
    case :mnesia.read(@hosts, host) do
      [{@hosts, _, n}] -> n
      [] -> 0
    end
  end

  # ------------------------------------------------------ complete / fail

  @doc "Mark a claimed job done."
  def complete(id, now) do
    tx(fn ->
      with {:ok, job} <- fetch_claimed(id) do
        release_host(job.host)
        drop_unique(job)
        :mnesia.write({@jobs, id, %{job | state: :completed, lease_until: nil, finished_at: now}})
        :ok
      end
    end)
  end

  @doc """
  Record a failed attempt. Retries after exponential backoff
  (`2^attempt` seconds, capped), or moves to `:dead` after `max_attempts`.
  Returns `{:retry, run_at}` or `:dead`.
  """
  def fail(id, error, now) do
    tx(fn ->
      with {:ok, job} <- fetch_claimed(id) do
        release_host(job.host)

        if job.attempt >= job.max_attempts do
          drop_unique(job)
          :mnesia.write({@jobs, id, %{job | state: :dead, lease_until: nil, finished_at: now, last_error: error}})
          :dead
        else
          run_at = now + backoff_ms(job.attempt)
          put_ready(%{job | state: :ready, run_at: run_at, lease_until: nil, last_error: error})
          {:retry, run_at}
        end
      end
    end)
  end

  @doc false
  def backoff_ms(attempt), do: min(:erlang.bsl(1000, attempt), @max_backoff_ms)

  defp fetch_claimed(id) do
    case :mnesia.read(@jobs, id) do
      [{@jobs, _, %{state: :claimed} = job}] -> {:ok, job}
      [{@jobs, _, job}] -> {:error, {:not_claimed, job.state}}
      [] -> {:error, :not_found}
    end
  end

  # ------------------------------------------------------------- lifeline

  @doc """
  Return claims whose lease has expired to the ready set (a crashed worker
  never reports back). The abandoned attempt still counts toward
  `max_attempts`; a job already at the limit goes to `:dead`.
  Returns the number of jobs recovered.
  """
  def lifeline(now) do
    tx(fn ->
      stale =
        :mnesia.select(@jobs, [
          {{@jobs, :"$1", %{state: :claimed, lease_until: :"$2"}}, [{:<, :"$2", now}], [:"$1"]}
        ])

      Enum.each(stale, fn id ->
        [{@jobs, _, job}] = :mnesia.read(@jobs, id)
        release_host(job.host)

        if job.attempt >= job.max_attempts do
          drop_unique(job)
          :mnesia.write({@jobs, id, %{job | state: :dead, lease_until: nil, finished_at: now, last_error: :lease_expired}})
        else
          put_ready(%{job | state: :ready, lease_until: nil, run_at: now, last_error: :lease_expired})
        end
      end)

      length(stale)
    end)
  end

  # ---------------------------------------------------------------- prune

  @doc "Delete terminal jobs finished more than `retention_ms` ago."
  def prune(now, retention_ms) do
    cutoff = now - retention_ms

    tx(fn ->
      old =
        :mnesia.select(@jobs, [
          {{@jobs, :"$1", %{state: :"$2", finished_at: :"$3"}},
           [{:orelse, {:==, :"$2", :completed}, {:==, :"$2", :dead}}, {:<, :"$3", cutoff}], [:"$1"]}
        ])

      Enum.each(old, &:mnesia.delete({@jobs, &1}))
      length(old)
    end)
  end

  # ---------------------------------------------------------------- reads

  def get(id) do
    case :mnesia.dirty_read(@jobs, id) do
      [{@jobs, _, job}] -> job
      [] -> nil
    end
  end

  @doc "Counts by state, plus `running` per host."
  def stats do
    jobs = :mnesia.dirty_select(@jobs, [{{@jobs, :_, :"$1"}, [], [:"$1"]}])
    by_state = Enum.frequencies_by(jobs, & &1.state)
    hosts = :mnesia.dirty_select(@hosts, [{{@hosts, :"$1", :"$2"}, [{:>, :"$2", 0}], [{{:"$1", :"$2"}}]}])
    %{by_state: by_state, running_by_host: Map.new(hosts), total: length(jobs)}
  end

  # -------------------------------------------------------------- helpers

  defp put_ready(job) do
    :mnesia.write({@jobs, job.id, job})
    :mnesia.write({@ready, {job.run_at, job.id}, job.id})
  end

  defp release_host(host) do
    case running(host) do
      n when n > 1 -> :mnesia.write({@hosts, host, n - 1})
      _ -> :mnesia.delete({@hosts, host})
    end
  end

  defp drop_unique(%{unique_key: nil}), do: :ok
  defp drop_unique(%{unique_key: key}), do: :mnesia.delete({@unique, key})

  # `sync_transaction` returns after the commit is flushed to the log on disk
  # (matters for :disc_copies); `config :mnesia_queue, sync: false` trades that
  # for speed.
  defp tx(fun) do
    run = if Application.get_env(:mnesia_queue, :sync, true), do: :sync_transaction, else: :transaction

    case apply(:mnesia, run, [fun]) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end
end

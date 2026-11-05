# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.Drain do
  @moduledoc """
  Quiet the server, then take a copy, before it is switched off.

  The order is the whole design (docs/OPS_DRAIN_BACKUP.ja.md):

    1. **close** — `SukhiShared.Intake` shuts the door. From here on every
       write and every federation inbox POST is a `503` + `Retry-After`
       (`SukhiFedi.Web.IntakePlug`); senders keep their activity and try
       again.
    2. **settle HTTP** — wait for the requests already inside to leave, then
       a short grace for the ones nobody counts (an inbox POST is verified
       and answered in one go).
    3. **flush the outbox** — wait until every accepted post has left the
       store's `outbox` table and its dispatch job has run, so nothing is
       half-way between Datalevin and the SQLite queue. Delivery jobs
       (one per remote inbox) are *not* waited for: they are durable in the
       queue and resume after the restart, and a dead peer would keep this
       waiting for hours.
    4. **stand still** — pause every Oban queue (gateway and delivery) and
       wait until none is running a job; the pull-federation puller starts
       nothing new and is waited for too.
    5. **back up** (`SukhiFedi.Maintenance.Backup`) — only now, and only on a
       closed, settled server.

  `open/1` undoes 1 and 4. A server that is shut down and started again is
  open anyway (see `SukhiShared.Intake`), which is how the normal flow ends.

  Every step is idempotent and every failure leaves the door **closed**: a
  half-finished drain is safer shut than open, and the operator reads the
  reason and either runs it again or opens. Nothing here shuts the process
  down; that is the unit's job (`scripts/sukhi-drain.sh run --stop`).

  What this does *not* stop: the Oban cron plugins keep inserting (paused)
  jobs; the metrics sampler and the optional graph mirror keep their own small
  writes; Pull Federation counters flush on their own timer. None of them is
  a user's data, and the backup does not need them to be still —
  `dtlv copy` and SQLite's `VACUUM INTO` are consistent on a database in use.

  Everything the procedure touches is reached through a `world` map of
  functions (`world/0`), so the order and the timeouts are tested without a
  database; `opts[:world]` replaces any of them.
  """

  import Ecto.Query

  alias SukhiFedi.Maintenance.Backup
  alias SukhiFedi.PullFederation.Puller
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.OutboxEvent
  alias SukhiFedi.Web.AdmissionQueue
  alias SukhiShared.Intake

  @poll_ms 250
  @http_timeout_ms 15_000
  @grace_ms 3_000
  @flush_timeout_ms 60_000
  @idle_timeout_ms 60_000

  @type reason :: term()

  # ── The procedure ─────────────────────────────────────────────────────────

  @doc """
  Close the door and settle (steps 1–4). `{:ok, status}` once nothing is
  writing; `{:error, reason}` with the door still shut.

  Options: `:reason` (word shown to visitors, default `"maintenance"`),
  `:until` (a `DateTime`), `:retry_after_s`, `:grace_ms`, `:http_timeout_ms`,
  `:flush_timeout_ms`, `:idle_timeout_ms`, `:poll_ms`, `:progress`
  (`fn step, detail_map -> any`), `:world`.
  """
  @spec close(keyword()) :: {:ok, Intake.t()} | {:error, reason()}
  def close(opts \\ []) do
    ctx = ctx(opts)

    Intake.close(Keyword.take(opts, [:reason, :until, :retry_after_s]))
    ctx.emit.(:intake_closed, %{})

    with :ok <- settle_http(ctx),
         :ok <- flush_outbox(ctx),
         :ok <- stand_still(ctx) do
      ctx.emit.(:settled, residual(ctx))
      {:ok, Intake.note(:settled_at, ctx.world.now.())}
    end
  end

  @doc """
  Back up a closed, settled server (step 5). Refuses on an open one: the
  point of this path is a copy taken while nothing writes. (`Backup.run/1`
  itself has no such rule and can be called on a live server.)
  """
  @spec backup(keyword()) :: {:ok, map()} | {:error, reason()}
  def backup(opts \\ []) do
    ctx = ctx(opts)

    case Intake.status() do
      %{state: :open} ->
        {:error, :not_closed}

      %{settled_at: nil} ->
        {:error, :not_settled}

      %{state: :closed} ->
        ctx.emit.(:backup_start, %{})

        with {:ok, info} <- Backup.run(Keyword.get(opts, :backup, [])) do
          Intake.note(:backup, %{dir: info.dir, at: ctx.world.now.()})
          ctx.emit.(:backup_done, %{dir: info.dir, bytes: info.bytes})
          {:ok, info}
        end
    end
  end

  @doc "`close/1` then `backup/1`. The door stays closed afterwards, ready for the shutdown."
  @spec run(keyword()) :: {:ok, map()} | {:error, reason()}
  def run(opts \\ []) do
    with {:ok, _status} <- close(opts), do: backup(opts)
  end

  @doc "Resume the queues and open the door."
  @spec open(keyword()) :: {:ok, Intake.t()}
  def open(opts \\ []) do
    ctx = ctx(opts)
    :ok = ctx.world.resume.()
    ctx.emit.(:queues_resumed, %{})
    status = Intake.open()
    ctx.emit.(:intake_open, %{})
    {:ok, status}
  end

  @doc "Where things stand: the door, the queues, what is waiting. Read-only."
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    w = world(opts)

    %{
      intake: Intake.marker(Intake.status()),
      marker: Intake.marker_status(),
      http_in_flight: w.http_in_flight.(),
      outbox_pending: w.outbox_pending.(),
      dispatch_active: w.dispatch_active.(),
      jobs: w.job_counts.(),
      queues_active: w.queues_active.(),
      puller_idle: w.puller_idle?.()
    }
  end

  # ── Steps ─────────────────────────────────────────────────────────────────

  defp settle_http(ctx) do
    attempts = attempts(ctx.http_timeout_ms, ctx.poll_ms)

    case wait(ctx, attempts, fn -> ctx.world.http_in_flight.() == 0 end) do
      :ok ->
        ctx.world.sleep.(ctx.grace_ms)
        ctx.emit.(:http_settled, %{grace_ms: ctx.grace_ms})
        :ok

      :timeout ->
        {:error, {:http_busy, %{in_flight: ctx.world.http_in_flight.()}}}
    end
  end

  defp flush_outbox(ctx) do
    attempts = attempts(ctx.flush_timeout_ms, ctx.poll_ms)

    flushed? = fn ->
      ctx.world.outbox_pending.() == 0 and ctx.world.dispatch_active.() == 0
    end

    case wait(ctx, attempts, flushed?) do
      :ok ->
        ctx.emit.(:outbox_flushed, %{})
        :ok

      :timeout ->
        {:error,
         {:flush_timeout,
          %{
            outbox_pending: ctx.world.outbox_pending.(),
            dispatch_active: ctx.world.dispatch_active.()
          }}}
    end
  end

  defp stand_still(ctx) do
    :ok = ctx.world.pause.()
    attempts = attempts(ctx.idle_timeout_ms, ctx.poll_ms)

    still? = fn -> ctx.world.queues_active.() == [] and ctx.world.puller_idle?.() end

    case wait(ctx, attempts, still?) do
      :ok ->
        ctx.emit.(:queues_paused, %{})
        :ok

      :timeout ->
        {:error,
         {:still_running,
          %{queues: ctx.world.queues_active.(), puller_idle: ctx.world.puller_idle?.()}}}
    end
  end

  # What is left behind, and durable: it resumes when the server comes back.
  defp residual(ctx) do
    %{
      outbox_pending: ctx.world.outbox_pending.(),
      jobs_waiting:
        ctx.world.job_counts.()
        |> Map.take(["available", "scheduled", "retryable"])
        |> Map.values()
        |> Enum.sum()
    }
  end

  # `attempts` polls, `poll_ms` apart, through the world's own `sleep`, so a
  # test with a no-op sleep and a condition that never holds ends — it does
  # not wait on a clock that never moves.
  defp wait(ctx, attempts, done?) do
    Enum.reduce_while(1..attempts, :timeout, fn _, _ ->
      if done?.() do
        {:halt, :ok}
      else
        ctx.world.sleep.(ctx.poll_ms)
        {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> if done?.(), do: :ok, else: :timeout
    end
  end

  defp attempts(timeout_ms, poll_ms), do: max(div(timeout_ms, poll_ms), 1)

  defp ctx(opts) do
    progress = Keyword.get(opts, :progress, fn _step, _detail -> :ok end)

    %{
      world: world(opts),
      emit: fn step, detail -> progress.(step, detail) end,
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      grace_ms: Keyword.get(opts, :grace_ms, @grace_ms),
      http_timeout_ms: Keyword.get(opts, :http_timeout_ms, @http_timeout_ms),
      flush_timeout_ms: Keyword.get(opts, :flush_timeout_ms, @flush_timeout_ms),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)
    }
  end

  # ── The world ─────────────────────────────────────────────────────────────

  @doc """
  What the procedure asks of the running system, as functions. `overrides`
  (the `:world` option) replace any of them.
  """
  @spec world(keyword()) :: map()
  def world(opts \\ []) do
    Map.merge(
      %{
        http_in_flight: &AdmissionQueue.running/0,
        outbox_pending: &outbox_pending/0,
        dispatch_active: &dispatch_active/0,
        job_counts: &job_counts/0,
        pause: fn -> each_oban(&Oban.pause_all_queues(&1, local_only: true)) end,
        resume: fn -> each_oban(&Oban.resume_all_queues(&1, local_only: true)) end,
        queues_active: &queues_active/0,
        puller_idle?: &puller_idle?/0,
        sleep: &Process.sleep/1,
        now: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
      },
      Keyword.get(opts, :world, %{})
    )
  end

  @doc "Every Oban instance in this BEAM that holds queues: the gateway's, and delivery's when combined."
  @spec oban_instances() :: [atom()]
  def oban_instances do
    [SukhiFedi.Oban | List.wrap(Application.get_env(:sukhi_fedi, :delivery_oban))]
    |> Enum.uniq()
    |> Enum.filter(&(Oban.whereis(&1) != nil))
  end

  defp each_oban(fun) do
    Enum.each(oban_instances(), fn name -> :ok = fun.(name) end)
  end

  # `{"Name", queue}` of every queue that is still taking jobs or running one.
  defp queues_active do
    for name <- oban_instances(),
        q <- Oban.check_all_queues(name),
        not (q.paused and q.running == []) do
      {name, q.queue}
    end
  end

  defp puller_idle? do
    if Process.whereis(Puller), do: Puller.idle?(), else: true
  end

  defp outbox_pending do
    from(e in OutboxEvent, select: filter(count(e.id), e.status == "pending"))
    |> Repo.one()
    |> Kernel.||(0)
  end

  # Dispatch jobs that are ready or running. `scheduled`/`retryable` ones are
  # waiting on a clock, not on us: they are durable and wait out the restart.
  defp dispatch_active do
    Enum.sum(
      for repo <- SukhiFedi.Queue.job_repos() do
        from(j in Oban.Job,
          where: j.queue == "outbox_dispatch" and j.state in ["available", "executing"],
          select: count(j.id)
        )
        |> repo.one()
        |> Kernel.||(0)
      end
    )
  end

  defp job_counts do
    Enum.reduce(SukhiFedi.Queue.job_repos(), %{}, fn repo, acc ->
      from(j in Oban.Job, group_by: j.state, select: {j.state, count(j.id)})
      |> repo.all()
      |> Enum.reduce(acc, fn {state, n}, acc -> Map.update(acc, state, n, &(&1 + n)) end)
    end)
  end

  # ── The command line ──────────────────────────────────────────────────────

  @doc """
  What `scripts/sukhi-drain.sh` calls through `bin/combined rpc`. The release
  prints what the expression prints and keeps no exit status, so the answer
  is the last line: `RESULT ok …` or `RESULT error …`. Progress lines before
  it are `STEP name key=value …`.
  """
  @spec cli(:status | :close | :backup | :run | :open, keyword()) :: :ok
  def cli(action, opts \\ []) when action in [:status, :close, :backup, :run, :open] do
    opts = Keyword.put_new(opts, :progress, &print_step/2)

    with {:ok, opts} <- parse_until(opts) do
      case apply_action(action, opts) do
        {:ok, %{dir: dir}} ->
          IO.puts("RESULT ok backup_dir=#{dir}")

        {:ok, %{} = detail} when action == :status ->
          IO.puts("RESULT ok #{JSON.encode!(jsonable(detail))}")

        {:ok, _} ->
          IO.puts("RESULT ok")

        {:error, reason} ->
          IO.puts("RESULT error #{inspect(reason)}")
      end
    else
      {:error, reason} -> IO.puts("RESULT error #{inspect(reason)}")
    end
  rescue
    error -> IO.puts("RESULT error #{inspect(Exception.message(error))}")
  end

  # The script hands `until` over as an ISO 8601 string.
  defp parse_until(opts) do
    case Keyword.fetch(opts, :until) do
      {:ok, text} when is_binary(text) ->
        case DateTime.from_iso8601(text) do
          {:ok, at, _offset} -> {:ok, Keyword.put(opts, :until, at)}
          {:error, _} -> {:error, {:bad_until, text}}
        end

      _ ->
        {:ok, opts}
    end
  end

  defp apply_action(:status, opts), do: {:ok, status(opts)}
  defp apply_action(:close, opts), do: close(opts)
  defp apply_action(:backup, opts), do: backup(opts)
  defp apply_action(:run, opts), do: run(opts)
  defp apply_action(:open, opts), do: open(opts)

  defp print_step(step, detail) do
    kv = Enum.map_join(detail, " ", fn {k, v} -> "#{k}=#{v}" end)
    IO.puts(String.trim("STEP #{step} #{kv}"))
  end

  # Tuples (queue ids, `{:error, _}`) and atoms keep their meaning as strings.
  defp jsonable(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(other) when is_binary(other) or is_number(other) or is_boolean(other), do: other
  defp jsonable(nil), do: nil
  defp jsonable(other), do: inspect(other)
end

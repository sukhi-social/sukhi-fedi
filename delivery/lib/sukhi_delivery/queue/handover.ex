# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue.Handover do
  @moduledoc """
  Moves the delivery jobs left in Postgres into the SQLite queue, once, at
  boot of a `DELIVERY_QUEUE=sqlite` node (see docs/DELIVERY_QUEUE_MIGRATION.md).

  Runs as a supervisor child that returns `:ignore`, after the SQLite queue
  exists and before the Postgres Oban starts, so nothing else is working the
  rows it moves. It is idempotent: moved rows are gone from Postgres, so a
  second run finds nothing.

  What moves: `delivery` and `outbox_dispatch` jobs that are `available`,
  `scheduled`, `retryable` or `executing`. An `executing` row can only be a
  leftover of the process that was stopped for the switch (the queue is
  single-node), so it comes back as `available`. Finished jobs stay where they
  are. The gateway's status reads look at both stores.

  Order is insert into SQLite, then delete from Postgres, so a crash can leave a
  job in both places but never in neither. The duplicate is harmless:
  `Delivery.Worker` dedups on `delivery_receipts`, and the relay skips outbox
  rows whose dispatch job is already queued.

  A failure is logged and boot goes on; the rows stay in Postgres and the next
  boot retries.
  """

  import Ecto.Query
  require Logger

  alias SukhiDelivery.QueueRepo

  @queues ~w(delivery outbox_dispatch)
  @states ~w(available scheduled retryable executing)
  @batch 500
  @fields ~w(state queue worker args meta tags errors attempt max_attempts priority
             attempted_at scheduled_at inserted_at)a

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    if Application.get_env(:sukhi_delivery, :queue_handover, true) do
      try do
        case run() do
          0 -> :ok
          n -> Logger.info("Queue.Handover moved #{n} job(s) from Postgres to SQLite")
        end
      rescue
        e -> Logger.error("Queue.Handover failed, will retry next boot: #{Exception.message(e)}")
      end
    end

    :ignore
  end

  @doc "Move everything movable from `source` (default Postgres). Returns the count."
  @spec run(module()) :: non_neg_integer()
  def run(source \\ SukhiDelivery.Repo), do: loop(source, 0)

  defp loop(source, total) do
    case move_batch(source) do
      0 -> total
      n -> loop(source, total + n)
    end
  end

  defp move_batch(source) do
    {:ok, n} =
      source.transaction(fn ->
        jobs = source.all(batch_query(source))

        unless jobs == [] do
          QueueRepo.insert_all(Oban.Job, Enum.map(jobs, &row/1))
          ids = Enum.map(jobs, & &1.id)
          source.delete_all(from(j in Oban.Job, where: j.id in ^ids))
        end

        length(jobs)
      end)

    n
  end

  defp batch_query(source) do
    query =
      from(j in Oban.Job,
        where: j.queue in ^@queues and j.state in ^@states,
        order_by: [asc: j.id],
        limit: @batch
      )

    # SKIP LOCKED keeps us off a row some other node is working.
    if source.__adapter__() == Ecto.Adapters.Postgres,
      do: lock(query, "FOR UPDATE SKIP LOCKED"),
      else: query
  end

  defp row(job) do
    job
    |> Map.take(@fields)
    |> Map.update!(:state, fn
      "executing" -> "available"
      state -> state
    end)
    |> Map.put(:attempted_at, nil)
    |> Map.update!(:attempt, &max(&1 - if(job.state == "executing", do: 1, else: 0), 0))
  end
end

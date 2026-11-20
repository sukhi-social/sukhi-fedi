# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Relay do
  @moduledoc """
  Consumes pending rows from the `outbox` table (written by the gateway via
  `SukhiFedi.Outbox.enqueue_multi/6`) and hands each one to
  `SukhiDelivery.Outbox.DispatchWorker`.

  The rows are in Datalevin and the jobs in PostgreSQL, so the two halves
  (insert the job, flip the row to `published`) cannot share a transaction.
  The hop is at-least-once: a crash between them leaves a `pending` row that
  already has a job, and `Queue.enqueued_outbox_ids/1` lets the next batch
  skip the insert and only flip it. Whatever still runs twice is absorbed by
  `delivery_receipts`.

  There is no LISTEN/NOTIFY to wake on and no row lock to take (one node, one
  writer): the relay polls, every `@poll_interval_ms`.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias SukhiDelivery.Outbox.DispatchWorker
  alias SukhiDelivery.Repo
  alias SukhiDelivery.Schema.OutboxEvent

  @poll_interval_ms 2_000
  @batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Catch rows that were inserted before this process came up.
    send(self(), :tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    publish_pending()
    Process.send_after(self(), :tick, @poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("SukhiDelivery.Outbox.Relay ignoring: #{inspect(msg)}")
    {:noreply, state}
  end

  defp publish_pending do
    Repo.transaction(fn ->
      from(e in OutboxEvent,
        where: e.status == "pending",
        order_by: [asc: e.id],
        limit: @batch_size
      )
      |> Repo.all()
      |> dispatch()
    end)
  rescue
    e ->
      Logger.error("Outbox.Relay batch failed: #{Exception.message(e)}")
      :error
  end

  # Insert one dispatch job per pending row and mark the rows published.
  # Anything that raises here (a payload the queue won't take, the job
  # table gone) leaves the rows `pending` for the next tick — the retry
  # budget lives on the Oban job, not here.
  defp dispatch([]), do: :ok

  defp dispatch(events) do
    # The job insert and the flip below are two stores, so a crash between
    # them leaves rows `pending` that are already queued. Skip those; they
    # only need the flip.
    queued = MapSet.new(SukhiDelivery.Queue.enqueued_outbox_ids(Enum.map(events, & &1.id)))

    events
    |> Enum.reject(&MapSet.member?(queued, &1.id))
    |> Enum.map(&job_for/1)
    |> case do
      [] -> :ok
      jobs -> SukhiDelivery.Queue.insert_all(jobs)
    end

    from(e in OutboxEvent, where: e.id in ^Enum.map(events, & &1.id))
    |> Repo.update_all(set: [status: "published", published_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  The Oban changeset for one outbox row. `outbox_id` rides along so a
  discarded job can be traced back to the row that produced it.
  """
  @spec job_for(OutboxEvent.t()) :: Ecto.Changeset.t()
  def job_for(%OutboxEvent{} = event) do
    DispatchWorker.new(%{
      "outbox_id" => event.id,
      "subject" => event.subject,
      "payload" => event.payload
    })
  end
end

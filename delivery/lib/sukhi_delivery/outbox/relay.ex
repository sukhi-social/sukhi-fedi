# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Relay do
  @moduledoc """
  Consumes pending rows from the `outbox` table (written by the gateway via
  `SukhiFedi.Outbox.enqueue_multi/6`) and hands each one to
  `SukhiDelivery.Outbox.DispatchWorker`.

  The rows and the jobs are in the same PostgreSQL database, so the two
  halves of the hop (insert the job, flip the row to `published`) are one
  transaction: both happen, or the row stays `pending`.

  There is no LISTEN/NOTIFY to wake on and no row lock to take (one node, one
  writer): the relay polls, every `@poll_interval_ms`.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias SukhiDelivery.Outbox.DispatchWorker
  alias SukhiDelivery.QueueRepo
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
    QueueRepo.transaction(fn ->
      from(e in OutboxEvent,
        where: e.status == "pending",
        order_by: [asc: e.id],
        limit: @batch_size
      )
      |> QueueRepo.all()
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
    events |> Enum.map(&job_for/1) |> SukhiDelivery.Queue.insert_all()

    from(e in OutboxEvent, where: e.id in ^Enum.map(events, & &1.id))
    |> QueueRepo.update_all(set: [status: "published", published_at: DateTime.utc_now()])

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

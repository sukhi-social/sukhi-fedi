# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Relay do
  @moduledoc """
  Consumes pending rows from the shared `outbox` table (written by the
  gateway via `SukhiFedi.Outbox.enqueue_multi/6`) and hands each one to
  `SukhiDelivery.Outbox.DispatchWorker`.

  Both halves happen in one transaction: the Oban job is inserted and the
  row flips to `published` together, or neither does. Same database, so
  there is no dual write and no window where a row says "done" while
  nothing is queued to act on it.

  Wakeups:
    * Postgres `NOTIFY outbox_new` (fired by the AFTER INSERT trigger
      installed by the gateway's outbox migration)
    * Periodic fallback tick

  Uses `FOR UPDATE SKIP LOCKED` so multiple relay instances cooperate
  safely — each claims a disjoint batch.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias SukhiDelivery.Outbox.DispatchWorker
  alias SukhiDelivery.Repo
  alias SukhiDelivery.Schema.OutboxEvent

  @poll_interval_ms 30_000
  @batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, notifier} = Postgrex.Notifications.start_link(postgrex_config())
    {:ok, _ref} = Postgrex.Notifications.listen(notifier, "outbox_new")

    # Catch rows that were inserted before this process came up.
    send(self(), :tick)

    {:ok, %{notifier: notifier}}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, "outbox_new", _payload}, state) do
    publish_pending()
    {:noreply, state}
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
        limit: @batch_size,
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> Repo.all()
      |> dispatch()
    end)
  rescue
    e ->
      Logger.error("Outbox.Relay batch failed: #{Exception.message(e)}")
      :error
  end

  # Insert one dispatch job per claimed row and mark the rows published.
  # Anything that raises here (a payload Postgres won't take, the job
  # table gone) rolls the whole batch back, leaving the rows `pending` for
  # the next tick — the retry budget lives on the Oban job, not here.
  defp dispatch([]), do: :ok

  defp dispatch(events) do
    events
    |> Enum.map(&job_for/1)
    |> then(&Oban.insert_all(SukhiDelivery.Oban, &1))

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

  defp postgrex_config do
    Repo.config()
    |> Keyword.take([
      :hostname,
      :port,
      :username,
      :password,
      :database,
      :ssl,
      :ssl_opts
    ])
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Relay do
  @moduledoc """
  Consumes pending rows from the shared `outbox` table (written by the
  gateway via `SukhiFedi.Outbox.enqueue_multi/6`) and hands each one to
  `SukhiDelivery.Outbox.DispatchWorker`.

  On the Postgres queue both halves happen in one transaction: the Oban job is inserted and the
  row flips to `published` together, or neither does. Same database, so
  there is no dual write and no window where a row says "done" while
  nothing is queued to act on it.

  Wakeups:
    * Postgres `NOTIFY outbox_new` (fired by the AFTER INSERT trigger
      installed by the gateway's outbox migration)
    * Periodic fallback tick

  On the Datalevin store there is no LISTEN/NOTIFY and no row lock to take
  (one node, one writer): the relay only polls, every `@datalevin_poll_ms`.

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
  @datalevin_poll_ms 2_000
  @batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    notifier =
      if Repo.datalevin?() do
        nil
      else
        {:ok, notifier} = Postgrex.Notifications.start_link(postgrex_config())
        {:ok, _ref} = Postgrex.Notifications.listen(notifier, "outbox_new")
        notifier
      end

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

    Process.send_after(
      self(),
      :tick,
      if(Repo.datalevin?(), do: @datalevin_poll_ms, else: @poll_interval_ms)
    )

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
      |> claim()
      |> Repo.all()
      |> dispatch()
    end)
  rescue
    e ->
      Logger.error("Outbox.Relay batch failed: #{Exception.message(e)}")
      :error
  end

  # Several relays cooperate through the row lock; Datalevin has one writer.
  defp claim(query) do
    if Repo.datalevin?(), do: query, else: lock(query, "FOR UPDATE SKIP LOCKED")
  end

  # Insert one dispatch job per claimed row and mark the rows published.
  # Anything that raises here (a payload Postgres won't take, the job
  # table gone) rolls the whole batch back, leaving the rows `pending` for
  # the next tick — the retry budget lives on the Oban job, not here.
  defp dispatch([]), do: :ok

  defp dispatch(events) do
    # With the SQLite queue the job insert and the flip below are two stores,
    # so a crash between them leaves rows `pending` that are already queued.
    # Skip those; they only need the flip.
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

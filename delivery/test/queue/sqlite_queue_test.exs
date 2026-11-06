# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue.SqliteQueueTest do
  # Runs without Postgres: `mix test --no-start test/queue`.
  use ExUnit.Case, async: false

  alias SukhiDelivery.{Queue, QueueRepo}
  alias SukhiDelivery.Outbox.{DispatchWorker, Relay}
  alias SukhiDelivery.Schema.OutboxEvent

  defmodule EchoWorker do
    use Oban.Worker, queue: :delivery, max_attempts: 2

    @impl true
    def perform(%Oban.Job{args: %{"reply_to" => pid}}) do
      send(:erlang.list_to_pid(String.to_charlist(pid)), :ran)
      :ok
    end
  end

  setup_all do
    path = Path.join(System.tmp_dir!(), "queue_#{System.unique_integer([:positive])}.db")
    Application.put_env(:sukhi_delivery, :queue_backend, :sqlite)

    Application.put_env(:sukhi_delivery, QueueRepo,
      database: path,
      journal_mode: :wal,
      pool_size: 2
    )

    Application.put_env(:sukhi_delivery, Oban, queues: [delivery: 2, outbox_dispatch: 1, push: 1])

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Application.ensure_all_started(:oban)
    start_supervised!(QueueRepo)
    Ecto.Migrator.run(QueueRepo, [{0, Queue.Migrate.Schema}], :up, all: true, log: false)

    start_supervised!(
      {Oban,
       name: SukhiDelivery.QueueOban,
       engine: Oban.Engines.Lite,
       repo: QueueRepo,
       queues: [delivery: 2],
       plugins: []}
    )

    on_exit(fn ->
      Application.delete_env(:sukhi_delivery, :queue_backend)
      File.rm(path)
    end)

    :ok
  end

  setup do
    QueueRepo.delete_all(Oban.Job)
    :ok
  end

  test "outbox_dispatch moves; delivery stays drained in Postgres for gateway-written jobs" do
    assert Queue.oban() == SukhiDelivery.QueueOban
    assert Keyword.keys(Queue.postgres_oban_config()[:queues]) == [:delivery, :push]
  end

  test "default backend is Postgres with nothing extra to start" do
    Application.put_env(:sukhi_delivery, :queue_backend, :postgres)
    on_exit(fn -> Application.put_env(:sukhi_delivery, :queue_backend, :sqlite) end)

    assert Queue.oban() == SukhiDelivery.Oban
    assert Queue.children() == []
    assert Queue.enqueued_outbox_ids([1]) == []
    assert Keyword.has_key?(Queue.postgres_oban_config()[:queues], :delivery)
  end

  test "a held delivery is snoozed on Lite without costing an attempt (FEP-f799)" do
    alias SukhiShared.DeliverySuspension.{Cache, Notice}

    start_supervised!(Cache)
    now = DateTime.utc_now()

    Cache.put(%Notice{
      id: "https://rest.example/suspensions/1",
      controller: "https://rest.example/users/ops",
      target_kind: :origin,
      target: "https://rest.example",
      revision: 1,
      published: DateTime.add(now, -60, :second),
      end_time: DateTime.add(now, 3600, :second),
      effective_start: DateTime.add(now, -30, :second),
      accepted_at: DateTime.add(now, -30, :second)
    })

    # The real worker: no activity_id, so it touches no relational database.
    Queue.insert_all([
      SukhiDelivery.Delivery.Worker.new(%{
        "inbox_url" => "https://rest.example/inbox",
        "raw_json" => %{"type" => "Create", "object" => %{"type" => "Note"}}
      })
    ])

    job = wait_for_job(fn j -> j.state == "scheduled" and j.meta["snoozed"] == 1 end)

    # Oban counted the run and took it back: the backoff is where it was,
    # and the 10-attempt ceiling is a whole 10 away.
    assert job.attempt == 0
    assert job.max_attempts == 10
    assert DateTime.diff(job.scheduled_at, now, :second) >= 3600 - 5
  end

  test "a delivery that has already failed keeps its attempts across the rest (FEP-f799)" do
    alias SukhiShared.DeliverySuspension.{Cache, Notice}

    start_supervised!(Cache)
    now = DateTime.utc_now()

    Cache.put(%Notice{
      id: "https://rest.example/suspensions/2",
      controller: "https://rest.example/users/ops",
      target_kind: :inbox,
      target: "https://rest.example/inbox",
      revision: 1,
      published: DateTime.add(now, -60, :second),
      end_time: DateTime.add(now, 3600, :second),
      effective_start: DateTime.add(now, -30, :second),
      accepted_at: DateTime.add(now, -30, :second)
    })

    # Put off for a minute, so the running queue leaves it alone while we make it
    # a job that has already been tried three times; then run it by hand.
    Queue.insert_all([
      SukhiDelivery.Delivery.Worker.new(
        %{
          "inbox_url" => "https://rest.example/inbox",
          "raw_json" => %{"type" => "Create", "object" => %{"type" => "Note"}}
        },
        schedule_in: 60
      )
    ])

    QueueRepo.update_all(Oban.Job, set: [attempt: 3, state: "available", scheduled_at: now])
    Oban.drain_queue(SukhiDelivery.QueueOban, queue: :delivery)

    # (the running queue may have taken it first; either way it ends up here)
    job = wait_for_job(fn j -> j.state == "scheduled" and j.meta["snoozed"] == 1 end)
    assert job.attempt == 3
  end

  defp wait_for_job(ready?, tries \\ 50) do
    job = QueueRepo.one(Oban.Job)

    cond do
      job && ready?.(job) ->
        job

      tries == 0 ->
        flunk("job never reached the expected state: #{inspect(job)}")

      true ->
        Process.sleep(100)
        wait_for_job(ready?, tries - 1)
    end
  end

  test "Oban Lite runs a delivery job from the SQLite file" do
    me = self() |> :erlang.pid_to_list() |> to_string()
    Queue.insert_all([EchoWorker.new(%{"reply_to" => me})])

    assert_receive :ran, 5_000
  end

  test "enqueued_outbox_ids reports rows already queued" do
    event = %OutboxEvent{id: 41, subject: "sns.outbox.note.created", payload: %{}}
    Queue.insert_all([Relay.job_for(event)])

    assert Queue.enqueued_outbox_ids([40, 41, 42]) == [41]
    assert DispatchWorker.__info__(:module) == DispatchWorker
  end

  test "the gateway's text-cast json queries work on SQLite" do
    Queue.insert_all([Relay.job_for(%OutboxEvent{id: 7, subject: "s", payload: %{}})])
    import Ecto.Query

    rows =
      from(j in "oban_jobs",
        where: fragment("CAST(?->>'outbox_id' AS TEXT)", j.args) in ^["7"],
        group_by: [fragment("CAST(?->>'outbox_id' AS TEXT)", j.args), j.state],
        select: {fragment("CAST(?->>'outbox_id' AS TEXT)", j.args), j.state, count(j.id)}
      )
      |> QueueRepo.all()

    assert [{"7", "available", 1}] = rows
  end
end

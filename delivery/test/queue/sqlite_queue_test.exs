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

  test "backend routing keeps push in Postgres and moves the busy queues" do
    assert Queue.oban() == SukhiDelivery.QueueOban
    assert Keyword.keys(Queue.postgres_oban_config()[:queues]) == [:push]
  end

  test "default backend is Postgres with nothing extra to start" do
    Application.put_env(:sukhi_delivery, :queue_backend, :postgres)
    on_exit(fn -> Application.put_env(:sukhi_delivery, :queue_backend, :sqlite) end)

    assert Queue.oban() == SukhiDelivery.Oban
    assert Queue.children() == []
    assert Queue.enqueued_outbox_ids([1]) == []
    assert Keyword.has_key?(Queue.postgres_oban_config()[:queues], :delivery)
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
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.QueueConfigTest do
  # Runs without a database: `mix test --no-start test/queue`.
  use ExUnit.Case, async: true

  alias SukhiDelivery.Queue

  test "one Oban, over the queue database, drains the delivery queues" do
    assert Queue.oban() == SukhiDelivery.Oban
    # Jobs this node writes for the gateway's queues go through the same instance.
    assert Queue.gateway_oban() == SukhiDelivery.Oban

    assert [SukhiDelivery.QueueRepo, SukhiDelivery.Queue.Migrate, {Oban, opts}] = Queue.children()
    assert opts[:name] == SukhiDelivery.Oban
    assert opts[:repo] == SukhiDelivery.QueueRepo

    queues = opts |> Keyword.fetch!(:queues) |> Keyword.keys()
    assert :delivery in queues
    assert :push in queues
    assert :outbox_dispatch in queues
  end
end

defmodule SukhiDelivery.QueueTest do
  # Needs PostgreSQL for the job tables (docs/TESTING.md):
  # `scripts/test-pgrust.sh` starts it and runs this with `--only integration`.
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SukhiDelivery.{Queue, QueueRepo}
  alias SukhiDelivery.Outbox.Relay
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
    # the suite runs with --no-start
    for app <- [:ecto_sql, :postgrex, :oban], do: {:ok, _} = Application.ensure_all_started(app)

    start_supervised!(QueueRepo)
    SukhiDelivery.Queue.Migrate.start_link()

    # Not `Queue.children/0`: the test config runs jobs inline, and these tests
    # watch a job move through the queue. The notifier is Erlang's own (no
    # LISTEN/NOTIFY to depend on), and staging polls so a new job is picked up.
    start_supervised!(
      {Oban,
       name: SukhiDelivery.Oban,
       repo: QueueRepo,
       notifier: Oban.Notifiers.PG,
       queues: [delivery: 2],
       stage_interval: 250,
       plugins: []}
    )

    :ok
  end

  setup do
    QueueRepo.delete_all(Oban.Job)
    :ok
  end

  test "a held delivery is snoozed without costing an attempt (FEP-f799)" do
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
    Oban.drain_queue(SukhiDelivery.Oban, queue: :delivery)

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

  test "Oban runs a delivery job out of PostgreSQL" do
    me = self() |> :erlang.pid_to_list() |> to_string()
    Queue.insert_all([EchoWorker.new(%{"reply_to" => me})])

    assert_receive :ran, 5_000
  end

  describe "the relay" do
    setup do
      QueueRepo.delete_all(OutboxEvent)
      :ok
    end

    defp pending_row do
      QueueRepo.insert!(%OutboxEvent{
        aggregate_type: "note",
        aggregate_id: "1",
        subject: "sns.outbox.note.created",
        payload: %{"note_id" => 1}
      })
    end

    test "turns a pending row into one job and marks it published, once" do
      %{id: id} = pending_row()

      for _ <- 1..2, do: Relay.handle_info(:tick, %{})

      assert [%{args: %{"outbox_id" => ^id}}] = QueueRepo.all(Oban.Job)
      assert %{status: "published", published_at: %DateTime{}} = QueueRepo.get!(OutboxEvent, id)
    end

    test "leaves no job behind when the row cannot be marked" do
      %{id: id} = pending_row()

      QueueRepo.query!("""
      CREATE FUNCTION refuse_mark() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'refused';
      END
      $$
      """)

      QueueRepo.query!(
        "CREATE TRIGGER refuse_mark BEFORE UPDATE ON outbox FOR EACH ROW EXECUTE FUNCTION refuse_mark()"
      )

      on_exit(fn ->
        QueueRepo.query!("DROP TRIGGER refuse_mark ON outbox")
        QueueRepo.query!("DROP FUNCTION refuse_mark()")
      end)

      ExUnit.CaptureLog.capture_log(fn -> Relay.handle_info(:tick, %{}) end)

      assert QueueRepo.all(Oban.Job) == []
      assert %{status: "pending"} = QueueRepo.get!(OutboxEvent, id)
    end
  end

  describe "a suspension hint in a response (FEP-f799)" do
    alias SukhiDelivery.Delivery.Worker

    @inbox "https://rest.example/inbox"
    @notice "https://rest.example/suspensions/1"
    @rel "https://w3id.org/fep/f799#deliverySuspension"

    # The hint is a job for the gateway's `suspension_hint` queue. This node's
    # Oban does not run that queue, so the job stays where it was put.
    defp hint_jobs do
      import Ecto.Query

      from(j in Oban.Job, where: j.worker == "SukhiFedi.Fedi.DeliverySuspension.Hint")
      |> QueueRepo.all()
    end

    defp answer(status \\ 202, link),
      do: {:ok, %{status: status, headers: %{"link" => [link]}, body: ""}}

    test "the address is passed to the gateway, once for a server that says it every time" do
      for _ <- 1..3 do
        assert :ok =
                 Worker.pass_on_suspension_hint(answer("<#{@notice}>; rel=\"#{@rel}\""), @inbox)
      end

      assert [
               %Oban.Job{
                 queue: "suspension_hint",
                 args: %{"url" => @notice, "inbox_url" => @inbox}
               }
             ] =
               hint_jobs()
    end

    test "any status can carry it, and a server error still points" do
      assert :ok =
               Worker.pass_on_suspension_hint(
                 answer(503, "<#{@notice}>; rel=\"#{@rel}\""),
                 @inbox
               )

      assert [_] = hint_jobs()
    end

    test "no hint, no job; a transport error is no hint" do
      assert :none = Worker.pass_on_suspension_hint({:ok, %{status: 202, headers: %{}}}, @inbox)
      assert :none = Worker.pass_on_suspension_hint(answer("<#{@notice}>; rel=\"next\""), @inbox)
      assert :none = Worker.pass_on_suspension_hint({:error, :timeout}, @inbox)
      assert [] = hint_jobs()
    end
  end
end

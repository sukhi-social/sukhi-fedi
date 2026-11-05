# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.DrainTest do
  # Not async: the intake state is one switch for the whole BEAM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SukhiFedi.Datalevin.Config
  alias SukhiFedi.Maintenance.Drain
  alias SukhiShared.Intake

  setup do
    dir = Path.join(System.tmp_dir!(), "drain-#{System.unique_integer([:positive])}")
    Application.put_env(:sukhi_shared, :intake_file, Path.join(dir, "intake.json"))
    Intake.open()

    on_exit(fn ->
      Intake.open()
      Application.delete_env(:sukhi_shared, :intake_file)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  # A world that answers from scripts (one element per question; the last one
  # repeats) and records what it was asked to do. `script` overrides answers:
  # `%{outbox: [3, 2, 1, 0]}`. Returns `{world, events_fun}`.
  defp fake(script \\ %{}) do
    answers =
      Map.merge(
        %{http: [0], outbox: [0], dispatch: [0], queues: [[]], puller: [true]},
        script
      )

    {:ok, agent} = Agent.start_link(fn -> %{answers: answers, events: []} end)

    ask = fn name ->
      fn ->
        Agent.get_and_update(agent, fn state ->
          case Map.fetch!(state.answers, name) do
            [last] -> {last, state}
            [head | rest] -> {head, put_in(state.answers[name], rest)}
          end
        end)
      end
    end

    note = fn event ->
      Agent.update(agent, fn state -> %{state | events: [event | state.events]} end)
    end

    world = %{
      http_in_flight: ask.(:http),
      outbox_pending: ask.(:outbox),
      dispatch_active: ask.(:dispatch),
      job_counts: fn -> %{"available" => 4, "retryable" => 2, "completed" => 90} end,
      queues_active: ask.(:queues),
      puller_idle?: ask.(:puller),
      pause: fn -> note.(:pause) end,
      resume: fn -> note.(:resume) end,
      sleep: fn ms -> note.({:sleep, ms}) end,
      now: fn -> ~U[2026-11-05 10:00:00Z] end
    }

    {world, fn -> agent |> Agent.get(& &1.events) |> Enum.reverse() end}
  end

  defp steps, do: Process.get(:steps, []) |> Enum.reverse() |> Keyword.keys()

  defp opts(world, extra \\ []) do
    Keyword.merge(
      [
        world: world,
        grace_ms: 10,
        poll_ms: 1,
        http_timeout_ms: 5,
        flush_timeout_ms: 5,
        idle_timeout_ms: 5,
        progress: fn step, detail ->
          Process.put(:steps, [{step, detail} | Process.get(:steps, [])])
        end
      ],
      extra
    )
  end

  # The command-line entry prints its own progress, so the recorder goes.
  defp quiet(opts), do: Keyword.delete(opts, :progress)

  defp backup_opts(dir, extra) do
    Keyword.merge(
      [
        root: Path.join(dir, "backups"),
        datalevin?: true,
        config: %Config{dir: Path.join(dir, "datalevin"), bin: "sh"},
        graph_dir: nil,
        queue_dbs: [],
        cmd: fn _exe, args ->
          if "copy" in args, do: File.mkdir_p!(List.last(args))
          {"ok", 0}
        end,
        free_bytes: fn _ -> :unknown end,
        manifest: fn path -> File.write(path, "{}") end
      ],
      extra
    )
  end

  describe "close/1" do
    test "shuts the door, settles in order, and says what is left behind" do
      {world, events} = fake()

      assert {:ok, %{state: :closed, settled_at: ~U[2026-11-05 10:00:00Z]}} =
               Drain.close(opts(world, reason: "update", retry_after_s: 90))

      assert Intake.closed?()
      assert %{reason: "update", retry_after_s: 90} = Intake.status()

      assert steps() == [:intake_closed, :http_settled, :outbox_flushed, :queues_paused, :settled]

      # waiting jobs are durable and resume after the restart; finished ones are not "waiting"
      assert {:settled, %{outbox_pending: 0, jobs_waiting: 6}} =
               List.keyfind(Process.get(:steps), :settled, 0)

      # paused exactly once, and the grace was honoured
      assert Enum.count(events.(), &(&1 == :pause)) == 1
      assert {:sleep, 10} in events.()
    end

    test "waits for the outbox to leave: nothing may be half-way between the stores" do
      {world, _events} = fake(%{outbox: [3, 2, 1, 0], dispatch: [1, 0]})

      assert {:ok, _} = Drain.close(opts(world, flush_timeout_ms: 50))
    end

    test "an outbox that never drains is an error, the door stays shut, nothing is paused" do
      {world, events} = fake(%{outbox: [3]})

      assert {:error, {:flush_timeout, %{outbox_pending: 3, dispatch_active: 0}}} =
               Drain.close(opts(world))

      assert Intake.closed?()
      assert %{settled_at: nil} = Intake.status()
      refute :pause in events.()
    end

    test "dispatch jobs that never finish are the same error" do
      {world, _events} = fake(%{dispatch: [2]})

      assert {:error, {:flush_timeout, %{dispatch_active: 2}}} = Drain.close(opts(world))
    end

    test "a queue that keeps running a job is an error and the door stays shut" do
      busy = [{SukhiFedi.Oban, "federation"}]
      {world, _events} = fake(%{queues: [busy]})

      assert {:error, {:still_running, %{queues: ^busy}}} = Drain.close(opts(world))

      assert Intake.closed?()
      assert %{settled_at: nil} = Intake.status()
    end

    test "a pull that keeps running blocks it too" do
      {world, _events} = fake(%{puller: [false]})

      assert {:error, {:still_running, %{puller_idle: false}}} = Drain.close(opts(world))
    end

    test "requests that never leave are an error before anything else is touched" do
      {world, events} = fake(%{http: [4]})

      assert {:error, {:http_busy, %{in_flight: 4}}} = Drain.close(opts(world))
      refute :pause in events.()
    end

    test "is idempotent: a second close of a settled server succeeds and keeps `since`" do
      {world, _events} = fake()

      assert {:ok, first} = Drain.close(opts(world))
      assert {:ok, second} = Drain.close(opts(world))
      assert first.since == second.since
    end
  end

  describe "backup/1" do
    test "refuses an open server: the point is a copy taken while nothing writes" do
      {world, _events} = fake()
      assert {:error, :not_closed} = Drain.backup(opts(world))
    end

    test "refuses a closed server that has not settled" do
      {world, _events} = fake()
      Intake.close()
      assert {:error, :not_settled} = Drain.backup(opts(world))
    end

    test "on a settled server, copies and notes the backup on the door", %{dir: dir} do
      {world, _events} = fake()
      assert {:ok, _} = Drain.close(opts(world))

      assert {:ok, %{dir: backup_dir}} = Drain.backup(opts(world, backup: backup_opts(dir, [])))

      assert File.regular?(Path.join(backup_dir, "backup-info.json"))
      assert %{backup: %{dir: ^backup_dir}} = Intake.status()

      marker = dir |> Path.join("intake.json") |> File.read!() |> JSON.decode!()
      assert %{"backup" => %{"dir" => ^backup_dir}} = marker
    end

    test "a failed copy is an error and leaves the door shut", %{dir: dir} do
      {world, _events} = fake()
      assert {:ok, _} = Drain.close(opts(world))

      failing = backup_opts(dir, cmd: fn _exe, _args -> {"disk on fire", 1} end)

      assert {:error, {:dtlv_copy, 1, "disk on fire"}} =
               Drain.backup(opts(world, backup: failing))

      assert Intake.closed?()
      assert %{backup: nil} = Intake.status()
    end

    test "run/1 is close then backup", %{dir: dir} do
      {world, _events} = fake()

      assert {:ok, %{dir: backup_dir}} = Drain.run(opts(world, backup: backup_opts(dir, [])))
      assert File.dir?(backup_dir)
      assert Intake.closed?()
    end
  end

  describe "open/1" do
    test "resumes the queues and opens the door" do
      {world, events} = fake()

      assert {:ok, _} = Drain.close(opts(world))
      assert {:ok, %{state: :open}} = Drain.open(opts(world))

      assert Intake.open?()
      assert :resume in events.()
    end
  end

  describe "cli/2" do
    test "prints STEP lines and ends with RESULT ok" do
      {world, _events} = fake()

      out = capture_io(fn -> Drain.cli(:close, quiet(opts(world))) end)
      lines = String.split(out, "\n", trim: true)

      assert "STEP intake_closed" in lines
      assert Enum.any?(lines, &String.starts_with?(&1, "STEP settled outbox_pending=0"))
      assert List.last(lines) == "RESULT ok"
    end

    test "the backup directory is on the RESULT line, for the script" do
      {world, _events} = fake()

      dir = Path.join(System.tmp_dir!(), "drain-cli-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      out =
        capture_io(fn ->
          Drain.cli(:run, quiet(opts(world, backup: backup_opts(dir, []))))
        end)

      assert out |> String.split("\n", trim: true) |> List.last() =~
               ~r|^RESULT ok backup_dir=#{Regex.escape(dir)}/backups/\d{8}T\d{6}Z$|
    end

    test "a failure is the last line, never a crash" do
      {world, _events} = fake(%{outbox: [3]})

      out = capture_io(fn -> Drain.cli(:close, quiet(opts(world))) end)

      assert out |> String.split("\n", trim: true) |> List.last() =~
               ~r/^RESULT error .*flush_timeout/
    end

    test "status is read-only and ends in one JSON document" do
      {world, _events} = fake()

      out = capture_io(fn -> Drain.cli(:status, quiet(opts(world))) end)
      "RESULT ok " <> json = out |> String.split("\n", trim: true) |> List.last()

      assert %{"intake" => %{"state" => "open"}, "outbox_pending" => 0, "puller_idle" => true} =
               JSON.decode!(json)

      assert Intake.open?()
    end
  end
end

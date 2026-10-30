# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue.HandoverTest do
  # Runs without Postgres: `mix test --no-start test/queue`. A second SQLite
  # repo stands in for the Postgres source.
  use ExUnit.Case, async: false

  alias SukhiDelivery.{Queue, QueueRepo}
  alias SukhiDelivery.Queue.Handover

  defmodule SourceRepo do
    use Ecto.Repo, otp_app: :sukhi_delivery, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    # `--no-start` leaves Ecto's repo registry down; the repos below need it.
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    dir = Path.join(System.tmp_dir!(), "handover_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {repo, name} <- [{QueueRepo, "dst.db"}, {SourceRepo, "src.db"}] do
      Application.put_env(:sukhi_delivery, repo, database: Path.join(dir, name), pool_size: 1)
      start_supervised!(repo)
      Ecto.Migrator.run(repo, [{0, Queue.Migrate.Schema}], :up, all: true, log: false)
    end

    on_exit(fn -> File.rm_rf(dir) end)
  end

  defp put(queue, state, extra \\ %{}) do
    Map.merge(
      %{
        queue: queue,
        state: state,
        worker: "W",
        args: %{"q" => queue, "s" => state},
        attempt: 1,
        max_attempts: 5,
        errors: [%{"error" => "boom"}]
      },
      extra
    )
    |> then(&SourceRepo.insert!(struct(Oban.Job, &1)))
  end

  test "moves live delivery jobs, keeps the rest, and is idempotent" do
    for s <- ~w(available scheduled retryable), do: put("delivery", s)
    put("outbox_dispatch", "available")
    put("delivery", "executing", %{attempt: 3})
    put("delivery", "completed")
    put("delivery", "discarded")
    put("push", "available")

    assert Handover.run(SourceRepo) == 5

    moved = QueueRepo.all(Oban.Job)
    assert length(moved) == 5
    assert Enum.all?(moved, &(&1.state in ~w(available scheduled retryable)))
    assert Enum.all?(moved, &(&1.errors == [%{"error" => "boom"}]))
    assert Enum.find(moved, &(&1.args["s"] == "executing")).attempt == 2
    assert Enum.find(moved, &(&1.args["s"] == "retryable")).state == "retryable"

    left = SourceRepo.all(Oban.Job) |> Enum.map(&{&1.queue, &1.state}) |> Enum.sort()
    assert left == [{"delivery", "completed"}, {"delivery", "discarded"}, {"push", "available"}]

    assert Handover.run(SourceRepo) == 0
    assert length(QueueRepo.all(Oban.Job)) == 5
  end

  test "moves more than one batch" do
    for _ <- 1..620, do: put("delivery", "available")
    assert Handover.run(SourceRepo) == 620
    assert QueueRepo.aggregate(Oban.Job, :count) == 620
  end
end

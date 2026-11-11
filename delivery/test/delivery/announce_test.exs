# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.AnnounceTest do
  # The jobs that tell the peers (FEP-f799): no network, no database.
  use ExUnit.Case, async: true

  alias SukhiDelivery.Delivery.{Announce, Worker}
  alias SukhiShared.DeliverySuspension.Spread

  @now ~U[2026-11-11 12:00:00Z]
  @ops "https://rest.example/users/ops"

  defp create,
    do: %{
      "id" => "https://rest.example/activities/suspension-m1-create",
      "type" => "Create",
      "actor" => @ops,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => %{"type" => "DeliverySuspension", "revision" => 1}
    }

  defp peers(n), do: for(i <- 1..n, do: "https://peer#{i}.example/inbox")

  test "one delivery job per peer, with the activity as it is, scheduled at its time" do
    plan = Spread.schedule(peers(30), per_second: 5)
    jobs = Announce.jobs(create(), plan, @now)

    assert length(jobs) == 30

    for {changeset, {inbox, delay}} <- Enum.zip(jobs, plan) do
      args = Ecto.Changeset.get_field(changeset, :args)
      assert args.raw_json == create()
      assert args.actor_uri == @ops
      assert args.activity_id == create()["id"]
      assert args.inbox_url == inbox

      assert Ecto.Changeset.get_field(changeset, :worker) == "SukhiDelivery.Delivery.Worker"

      assert DateTime.compare(
               Ecto.Changeset.get_field(changeset, :scheduled_at),
               DateTime.add(@now, delay, :millisecond)
             ) == :eq
    end
  end

  test "the times are the plan's: spread, not one wave" do
    plan = Spread.schedule(peers(100), per_second: 10)

    times =
      create()
      |> Announce.jobs(plan, @now)
      |> Enum.map(&Ecto.Changeset.get_field(&1, :scheduled_at))

    assert length(Enum.uniq(times)) > 80
    assert Enum.all?(times, &(DateTime.compare(&1, @now) != :lt))
  end

  test "the jobs are for the delivery worker, which never holds a suspension notice" do
    plan = Spread.schedule(["https://peer.example/inbox"])
    [changeset] = Announce.jobs(create(), plan, @now)

    assert Ecto.Changeset.get_field(changeset, :worker) ==
             to_string(Worker) |> String.replace("Elixir.", "")

    # the worker would not hold what it carries
    assert SukhiShared.DeliverySuspension.Gate.exempt?(create())
  end

  test "one inbox per host, our own host and non-URLs left out" do
    inboxes = [
      "https://a.example/users/x/inbox",
      "https://a.example/inbox",
      "https://B.example/inbox",
      nil,
      "https://rest.example/users/ops/inbox",
      "not a url"
    ]

    assert ["https://a.example/users/x/inbox", "https://B.example/inbox"] =
             Announce.one_per_host(inboxes, "rest.example")
  end

  test "no audience, no jobs; something that is not an activity is refused" do
    assert {:ok, %{count: 0}} = Announce.run(create(), inboxes: [], now: @now)
    assert {:error, :not_an_activity} = Announce.run(%{"type" => "Create"})
  end

  describe "SukhiDelivery.Release.read_activity/1" do
    @tag :tmp_dir
    test "an activity file is read; a missing or broken one is a clear error", %{tmp_dir: dir} do
      good = Path.join(dir, "good.json")
      File.write!(good, JSON.encode!(create()))
      assert {:ok, activity} = SukhiDelivery.Release.read_activity(good)
      assert activity == create()

      assert {:error, {:unreadable, :enoent}} =
               SukhiDelivery.Release.read_activity(Path.join(dir, "nope.json"))

      bad = Path.join(dir, "bad.json")
      File.write!(bad, "[1,2]")
      assert {:error, {:unreadable, :not_an_object}} = SukhiDelivery.Release.read_activity(bad)

      File.write!(bad, "{oops")
      assert {:error, {:unreadable, _}} = SukhiDelivery.Release.read_activity(bad)
    end
  end
end

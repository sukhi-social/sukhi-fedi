# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule ProofTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Origin, Proof, Puller, Sim}

  @act %{id: "p1", type: :create, visibility: :public}

  setup do
    kp = Proof.keypair()
    other = Proof.keypair()

    origin =
      Origin.new(signers: %{"alice" => {"alice#key", kp.private}})
      |> Origin.follow("b.example", "alice")

    keys = %{"alice" => kp.public}
    {:ok, kp: kp, other: other, origin: origin, keys: keys}
  end

  defp puller(verify),
    do: Puller.new(verify: verify) |> Puller.follow("a.example", "alice")

  test "an activity is signed once at publish and carries actor and proof", %{origin: o} do
    {o, _} = Origin.publish(o, "alice", @act)
    [event] = o.log["alice"]
    assert event.activity.actor == "alice" and byte_size(event.activity.proof.sig) == 64
  end

  test "pulled activities verify and are stored", %{origin: o, keys: keys} do
    {o, _} = Origin.publish(o, "alice", @act)
    {_, [{"b.example", ann}]} = Origin.due_notifications(o, 10_000)
    b = puller(Proof.verifier(keys))
    {b, :planned} = Puller.notify(b, "a.example", ann, 0)
    {_, b} = Sim.round(o, "b.example", b, now: 10_000, origin_domain: "a.example")
    assert Map.has_key?(b.store, "p1") and b.rejected == 0
  end

  test "an activity changed after signing is rejected", %{origin: o, keys: keys} do
    {o, _} = Origin.publish(o, "alice", @act)
    [event] = o.log["alice"]
    tampered = Map.put(event.activity, :visibility, :followers)
    b = Puller.apply_activity(puller(Proof.verifier(keys)), tampered, 0)
    assert b.rejected == 1 and b.store == %{}
  end

  test "an activity relabelled to another actor is rejected", %{origin: o, keys: keys} do
    {o, _} = Origin.publish(o, "alice", @act)
    [event] = o.log["alice"]

    b =
      Puller.apply_activity(
        puller(Proof.verifier(Map.put(keys, "bob", keys["alice"]))),
        %{event.activity | actor: "bob"},
        0
      )

    assert b.rejected == 1
  end

  test "an origin without the actor's key cannot forge her activities, or her deletes", %{
    other: other,
    keys: keys
  } do
    forged = Proof.sign(@act, "alice", "alice#key", other.private)

    delete =
      Proof.sign(%{id: "d1", type: :delete, object: "p1"}, "alice", "alice#key", other.private)

    b = puller(Proof.verifier(keys))
    b = b |> Puller.apply_activity(forged, 0) |> Puller.apply_activity(delete, 0)
    assert b.rejected == 2 and b.store == %{} and MapSet.size(b.tombstones) == 0
  end

  test "an unsigned activity is rejected by the verifier", %{keys: keys} do
    b = Puller.apply_activity(puller(Proof.verifier(keys)), @act, 0)
    assert b.rejected == 1
  end

  test "pushed activities go through the same check", %{origin: o, keys: keys} do
    {o, _} = Origin.publish(o, "alice", @act)
    [e] = o.log["alice"]
    good = %{key: e.key, etag: e.etag, prev: e.prev, activity: e.activity}
    bad = %{good | activity: Map.put(e.activity, :id, "other")}
    b = puller(Proof.verifier(keys))
    {b, _} = Puller.receive_push(b, "a.example", bad, 0)
    assert b.rejected == 1 and b.store == %{}
    {b, _} = Puller.receive_push(b, "a.example", good, 0)
    assert Map.has_key?(b.store, "p1")
  end
end

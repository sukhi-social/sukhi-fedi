# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule RequestAuthTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Etag, Origin, RequestAuth}

  @target "https://a.example/pull"

  setup do
    d1 = RequestAuth.keypair()
    d2 = RequestAuth.keypair()
    evil = RequestAuth.keypair()

    o =
      Origin.new()
      |> Origin.follow("d1", "alice")
      |> Origin.follow("d2", "alice")

    {o, _} = Origin.publish(o, "alice", %{id: "pub", type: :create, visibility: :public})
    {o, _} = Origin.publish(o, "alice", %{id: "fol", type: :create, visibility: :followers})
    keys = %{"d1" => d1.public, "d2" => d2.public}
    {:ok, o: o, d1: d1, d2: d2, evil: evil, keys: keys}
  end

  defp ids({_, {:ok, events, _}}), do: Enum.map(events, & &1.activity.id) |> Enum.sort()

  test "a correctly signed request is served, including followers-only", c do
    req = RequestAuth.sign("d1", @target, %{}, 1_000, c.d1.private)

    assert ids(Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000)) == [
             "fol",
             "pub"
           ]
  end

  test "claiming another domain's name with one's own key gets nothing", c do
    req = RequestAuth.sign("d1", @target, %{}, 1_000, c.evil.private)

    assert {_, {:error, :unauthenticated}} =
             Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000)

    # a valid signature by d2, relabelled as d1
    req = RequestAuth.sign("d2", @target, %{}, 1_000, c.d2.private) |> Map.put(:domain, "d1")

    assert {_, {:error, :unauthenticated}} =
             Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000)
  end

  test "no signature, unknown domain, wrong target and changed cursors are refused", c do
    assert {_, {:error, :unauthenticated}} =
             Origin.authenticated_stream(c.o, nil, c.keys, @target, %{}, 1_000)

    req = RequestAuth.sign("zzz", @target, %{}, 1_000, c.evil.private)

    assert {_, {:error, :unauthenticated}} =
             Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000)

    req = RequestAuth.sign("d1", @target, %{}, 1_000, c.d1.private)

    assert {_, {:error, :unauthenticated}} =
             Origin.authenticated_stream(c.o, req, c.keys, "https://other/pull", %{}, 1_000)

    assert {_, {:error, :unauthenticated}} =
             Origin.authenticated_stream(
               c.o,
               req,
               c.keys,
               @target,
               %{"alice" => Etag.ordered(1)},
               1_000
             )
  end

  test "the window is 60 s: expired and not-yet-valid requests are refused", c do
    req = RequestAuth.sign("d1", @target, %{}, 1_000, c.d1.private)
    after_window = 1_000 + RequestAuth.window_ms() + 1

    assert {_, {:error, :expired}} =
             Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, after_window)

    assert {_, {:error, :expired}} =
             Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000 - 6_000)
  end

  test "a captured request cannot be replayed inside its window", c do
    req = RequestAuth.sign("d1", @target, %{}, 1_000, c.d1.private)
    {o, {:ok, _, _}} = Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000)
    o = Origin.close_stream(o, "d1", 1_100)

    assert {_, {:error, :replayed}} =
             Origin.authenticated_stream(o, req, c.keys, @target, %{}, 2_000)
  end

  test "spent nonces are forgotten after the window, so the table stays small", c do
    req = RequestAuth.sign("d1", @target, %{}, 1_000, c.d1.private)
    {o, {:ok, _, _}} = Origin.authenticated_stream(c.o, req, c.keys, @target, %{}, 1_000)
    assert map_size(o.nonces) == 1
    req2 = RequestAuth.sign("d2", @target, %{}, 100_000, c.d2.private)
    {o, _} = Origin.authenticated_stream(o, req2, c.keys, @target, %{}, 100_000)
    assert map_size(o.nonces) == 1
  end

  test "refusals cost no slot and book nothing", c do
    {o, {:error, :unauthenticated}} =
      Origin.authenticated_stream(c.o, nil, c.keys, @target, %{}, 1)

    assert o.active_streams == 0 and o.calendar.booked == 0 and o.open == %{}
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

# Stands in for a live `:gnat`. `Gnat.sub/4` is just a
# `GenServer.call(pid, {:sub, subscriber, topic, opts})`, so answering that
# one call is enough to walk the listener through a real subscribe.
defmodule SukhiFedi.Addons.Streaming.NatsListenerTest.FakeGnat do
  @moduledoc false
  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, nil, name: :gnat)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:sub, _subscriber, _topic, _opts}, _from, state), do: {:reply, {:ok, 1}, state}
end

defmodule SukhiFedi.Addons.Streaming.NatsListenerTest do
  # Not async: the listener registers under its own module name.
  use ExUnit.Case, async: false

  alias SukhiFedi.Addons.Streaming.NatsListener
  alias SukhiFedi.Addons.Streaming.NatsListenerTest.FakeGnat

  # It used to subscribe in init/1, and Gnat.sub does not return an error
  # when `:gnat` is missing — it exits. Gnat.ConnectionSupervisor connects
  # asynchronously, so on 2026-08-24 a deploy found the gap: the whole
  # application failed to boot on `failed_to_start_child: NatsListener`.
  setup do
    refute Process.whereis(:gnat), "this test only means anything without :gnat"
    :ok
  end

  test "starts with no NATS connection instead of taking the app down" do
    {:ok, pid} = NatsListener.start_link([])

    # Getting a reply at all means init/1 and the {:continue, :subscribe}
    # both finished — the exit, if it came, came from in there.
    assert :sys.get_state(pid) == %{subscribed: false, gnat: nil}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "a retry that finds no NATS either is survived, not crashed on" do
    {:ok, pid} = NatsListener.start_link([])

    send(pid, :resubscribe)

    assert :sys.get_state(pid) == %{subscribed: false, gnat: nil}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  # A subscription hangs off the `:gnat` connection process, and nothing
  # tells us when that one dies. On 2026-08-27 NATS was restarted to drop
  # JetStream: `fedify.>` re-subscribed itself, this listener did not, and
  # timeline SSE/WS updates stopped until the app was restarted. So the
  # connection is monitored now. `SukhiFedi.WtRelayTelemetry` carries the
  # same shape.
  test "a dropped connection puts it back to unsubscribed, and it retries" do
    {:ok, pid} = NatsListener.start_link([])
    ref = make_ref()
    :sys.replace_state(pid, fn s -> %{s | subscribed: true, gnat: ref} end)

    send(pid, {:DOWN, ref, :process, self(), :shutdown})

    # Back to square one, which is what `:resubscribe` needs to find to
    # try `Gnat.sub` again — `try_subscribe/1` is a no-op while subscribed.
    assert :sys.get_state(pid) == %{subscribed: false, gnat: nil}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "subscribing monitors the connection, and its death sends it back to retrying" do
    {:ok, gnat} = FakeGnat.start_link()
    {:ok, pid} = NatsListener.start_link([])

    # The real path: whereis → Gnat.sub → Process.monitor.
    assert %{subscribed: true, gnat: ref} = :sys.get_state(pid)
    assert is_reference(ref)

    # The connection dying is what takes the subscription with it. `stop`
    # returns only once the process is gone, so the :DOWN is already in the
    # listener's mailbox — ahead of the :sys.get_state call below.
    GenServer.stop(gnat)

    assert :sys.get_state(pid) == %{subscribed: false, gnat: nil}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "a :DOWN from a monitor it no longer watches is ignored" do
    {:ok, pid} = NatsListener.start_link([])
    ref = make_ref()
    :sys.replace_state(pid, fn s -> %{s | subscribed: true, gnat: ref} end)

    # The previous connection's monitor, arriving after we already moved on.
    send(pid, {:DOWN, make_ref(), :process, self(), :shutdown})

    assert :sys.get_state(pid) == %{subscribed: true, gnat: ref}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end
end

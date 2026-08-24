# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Streaming.NatsListenerTest do
  # Not async: the listener registers under its own module name.
  use ExUnit.Case, async: false

  alias SukhiFedi.Addons.Streaming.NatsListener

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
    assert :sys.get_state(pid) == %{subscribed: false}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end

  test "a retry that finds no NATS either is survived, not crashed on" do
    {:ok, pid} = NatsListener.start_link([])

    send(pid, :resubscribe)

    assert :sys.get_state(pid) == %{subscribed: false}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end
end

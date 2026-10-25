# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RpcGateLimitTest do
  # Not async: it lowers the app-wide cap for the duration.
  use ExUnit.Case, async: false

  alias SukhiFedi.RpcGate

  setup do
    prev = Application.get_env(:sukhi_fedi, :rpc_max_in_flight)
    Application.put_env(:sukhi_fedi, :rpc_max_in_flight, 2)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:sukhi_fedi, :rpc_max_in_flight, prev),
        else: Application.delete_env(:sukhi_fedi, :rpc_max_in_flight)
    end)
  end

  defp slow_call(ms), do: Task.async(fn -> RpcGate.call(Process, :sleep, [ms]) end)

  test "refuses past the cap instead of queueing, and recovers" do
    a = slow_call(300)
    b = slow_call(300)
    Process.sleep(50)

    assert RpcGate.call(Kernel, :+, [1, 1]) == {:badrpc, :overloaded}

    assert Task.await(a) == :ok
    assert Task.await(b) == :ok
    assert RpcGate.call(Kernel, :+, [1, 1]) == 2
  end

  test "a call killed mid-way does not keep its slot" do
    a = slow_call(5_000)
    b = slow_call(5_000)
    Process.sleep(50)
    Process.unlink(a.pid)
    Process.unlink(b.pid)
    Process.exit(a.pid, :kill)
    Process.exit(b.pid, :kill)
    Process.sleep(50)

    assert RpcGate.call(Kernel, :+, [1, 1]) == 2
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.GatewayRpcTest do
  use ExUnit.Case, async: false

  alias SukhiApi.GatewayRpc

  # Answers whatever the test stored under :gateway_rpc_test_answer, the way
  # `:rpc.call` would: the callee's return value, wrapped once by `call/4`.
  defmodule Fake do
    def call(_mod, _fun, _args, _timeout), do: Application.fetch_env!(:sukhi_api, :gateway_rpc_test_answer)
  end

  setup do
    prev = Application.get_env(:sukhi_api, :gateway_rpc_impl)
    Application.put_env(:sukhi_api, :gateway_rpc_impl, Fake)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:sukhi_api, :gateway_rpc_impl, prev),
        else: Application.delete_env(:sukhi_api, :gateway_rpc_impl)

      Application.delete_env(:sukhi_api, :gateway_rpc_test_answer)
    end)
  end

  defp answer(term), do: Application.put_env(:sukhi_api, :gateway_rpc_test_answer, term)
  defp run, do: GatewayRpc.run(SukhiFedi.Social, :anything, [])

  describe "run/4" do
    test "{:ok, x} from the gateway function is {:ok, x}, not {:ok, {:ok, x}}" do
      answer({:ok, {:ok, :follow}})
      assert run() == {:ok, :follow}
    end

    test "{:error, e} from the gateway function is {:error, e}" do
      answer({:ok, {:error, :not_found}})
      assert run() == {:error, :not_found}
    end

    test "a bare return is {:ok, value}" do
      for bare <- [[1, 2], %{a: 1}, nil, :ok] do
        answer({:ok, bare})
        assert run() == {:ok, bare}
      end
    end

    test "transport failures are {:unavailable, why}, never {:error, _}" do
      answer({:error, :not_connected})
      assert run() == {:unavailable, :not_connected}

      answer({:error, {:badrpc, :nodedown}})
      assert run() == {:unavailable, {:badrpc, :nodedown}}
    end
  end

  describe "unavailable_body/1" do
    test "matches what the capabilities have been answering" do
      assert GatewayRpc.unavailable_body(:not_connected) == %{error: "gateway_not_connected"}

      assert GatewayRpc.unavailable_body({:badrpc, :nodedown}) ==
               %{error: "gateway_rpc_failed", detail: ":nodedown"}
    end
  end
end

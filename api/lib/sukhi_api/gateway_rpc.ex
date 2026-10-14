# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.GatewayRpc do
  @moduledoc """
  Thin wrapper over `:rpc.call/5` for plugin capabilities that need
  to read or mutate data owned by the gateway BEAM node
  (`SukhiFedi.*` context modules).

  The gateway node is read from `Application.get_env(:sukhi_api, :gateway_node)`,
  which in production is supplied via the `GATEWAY_NODE` env var
  (see `api/config/runtime.exs`).

  **Use `run/4`.** It answers `{:ok, x} | {:error, e} | {:unavailable, why}`
  and `unavailable_body/1` is the 503 body for the last one, so a capability
  is one `case` with one transport clause. `call/4` below is the raw layer
  `run/4` stands on, and the seam tests replace; it wraps whatever the
  gateway function returned, so `{:ok, x}` arrives as `{:ok, {:ok, x}}`:

    * `{:ok, value}`       — on a successful call (value is the callee's return)
    * `{:error, {:badrpc, reason}}` — gateway unreachable or crashed
    * `{:error, :not_connected}`    — Erlang distribution disabled /
                                      no node configured

  ## Test impl injection

  Tests can substitute the entire RPC layer by setting

      Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)

  where `FakeRpc.call/3,4` returns the same `{:ok, term} | {:error, term}`
  shape. When unset, the real `:rpc.call` is used. This keeps capability
  code free of test indirection.
  """

  @default_timeout 5_000

  @spec call(module(), atom(), [term()], pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def call(mod, fun, args, timeout \\ @default_timeout)
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    case Application.get_env(:sukhi_api, :gateway_rpc_impl) do
      nil -> do_call(mod, fun, args, timeout)
      impl when is_atom(impl) -> impl.call(mod, fun, args, timeout)
    end
  end

  @typedoc """
  What `run/4` answers. Three outcomes, three shapes, no nesting:

    * `{:ok, value}`        — the gateway function succeeded
    * `{:error, reason}`    — it ran and said no (a domain error)
    * `{:unavailable, why}` — it never ran: `:not_connected` or `{:badrpc, reason}`
  """
  @type result :: {:ok, term()} | {:error, term()} | {:unavailable, term()}

  @doc """
  Like `call/4`, but flattened.

  `call/4` wraps whatever the gateway function returned, so a context
  function that answers `{:ok, x}` or `{:error, e}` arrives as
  `{:ok, {:ok, x}}` / `{:ok, {:error, e}}` — and a caller that forgets the
  inner layer turns a transport failure into a `MatchError` (a 500). Here the
  inner tuple replaces the outer one, and transport failures get their own
  tag, so `{:error, _}` always means "the gateway answered". A bare return
  (a list, a map, `nil`, `:ok`) is `{:ok, value}`.
  """
  @spec run(module(), atom(), [term()], pos_integer()) :: result()
  def run(mod, fun, args, timeout \\ @default_timeout) do
    case call(mod, fun, args, timeout) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      {:error, :not_connected} -> {:unavailable, :not_connected}
      {:error, {:badrpc, _} = why} -> {:unavailable, why}
    end
  end

  @doc """
  The JSON body for a 503 when `run/4` says `{:unavailable, why}`.
  """
  @spec unavailable_body(term()) :: map()
  def unavailable_body(:not_connected), do: %{error: "gateway_not_connected"}

  def unavailable_body({:badrpc, reason}),
    do: %{error: "gateway_rpc_failed", detail: inspect(reason)}

  defp do_call(mod, fun, args, timeout) do
    case gateway_node() do
      nil ->
        {:error, :not_connected}

      node ->
        _ = maybe_connect(node)

        case :rpc.call(node, mod, fun, args, timeout) do
          {:badrpc, reason} -> {:error, {:badrpc, reason}}
          other -> {:ok, other}
        end
    end
  end

  defp gateway_node do
    case Application.get_env(:sukhi_api, :gateway_node) do
      nil -> nil
      n when is_atom(n) -> n
      n when is_binary(n) -> String.to_atom(n)
    end
  end

  # `Node.connect/1` is idempotent; once we're connected it returns true
  # quickly. Failures become `false` / `:ignored` which we tolerate —
  # the following `:rpc.call` will surface a `{:badrpc, :nodedown}`.
  defp maybe_connect(node) do
    case :net_kernel.connect_node(node) do
      true -> :ok
      _ -> :ignored
    end
  rescue
    _ -> :ignored
  end
end

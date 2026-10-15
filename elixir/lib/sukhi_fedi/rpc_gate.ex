# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RpcGate do
  @moduledoc """
  The one door the api node's RPC comes through (`SukhiApi.GatewayRpc`).

  It runs `mod.fun(args)` and hands back the result with the secret fields
  blanked, wherever they sit in it: a bare `%Account{}`, one inside
  `{:ok, %{account: ..., app: ...}}`, a list of them, a loaded association.
  The api node caches the result in ETS and keeps it in request assigns, and
  never reads a key, a password hash or a TOTP secret; so none of them leaves
  the gateway. The check is here, once, not in each function that happens to
  return an account.

  Blanked means `nil`, not removed: the struct and its shape stay, and a
  pattern that names the field still matches.

  Only values crossing *out* are touched. An account the api hands back in
  (as a viewer) comes with those fields already `nil`; nothing the api calls
  reads them from it (the gateway's own web controllers load accounts
  themselves).
  """

  # Field names, in Ecto schemas (Account, Deco, …) and in plain maps.
  @secret_fields [
    :private_key_jwk,
    :ed25519_private_key_jwk,
    :password_hash,
    :totp_secret,
    :totp_last_used_step
  ]

  @doc "Run `apply(mod, fun, args)` and return what leaves, scrubbed."
  @spec call(module(), atom(), [term()]) :: term()
  def call(mod, fun, args) when is_atom(mod) and is_atom(fun) and is_list(args) do
    mod |> apply(fun, args) |> scrub()
  end

  @doc false
  @spec secret_fields() :: [atom()]
  def secret_fields, do: @secret_fields

  @doc "The value with every secret field blanked. Exposed for tests."
  @spec scrub(term()) :: term()
  def scrub(%module{} = struct) do
    if schema?(module) do
      Enum.reduce(Map.from_struct(struct), struct, fn {key, value}, acc ->
        Map.put(acc, key, scrub_field(key, value))
      end)
    else
      # DateTime, Decimal, MapSet, NotLoaded, Metadata … opaque; leave alone.
      struct
    end
  end

  def scrub(%{} = map), do: Map.new(map, fn {key, value} -> {key, scrub_field(key, value)} end)
  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)

  def scrub(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()
  end

  def scrub(other), do: other

  defp scrub_field(key, _value) when key in @secret_fields, do: nil
  defp scrub_field(_key, value), do: scrub(value)

  defp schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
  end
end

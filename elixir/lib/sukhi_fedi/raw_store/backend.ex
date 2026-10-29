# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore.Backend do
  @moduledoc """
  The small contract a blob store meets: a key (`sha256:<hex>`), its bytes,
  and enough listing to garbage-collect. Keys are content addresses, so
  `put/3` is idempotent.
  """

  @callback put(key :: String.t(), body :: binary(), opts :: keyword()) :: :ok | {:error, term()}
  @callback get(key :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, :missing | term()}
  @callback exists?(key :: String.t(), opts :: keyword()) :: boolean()
  @callback delete(key :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  @doc "Keys written at or before `unix` (seconds)."
  @callback list_older_than(unix :: integer(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}
end

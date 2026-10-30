# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store do
  @moduledoc """
  Which database holds the business data: `:postgres` (default) or `:datalevin`.

  `SUKHI_STORE=datalevin` selects Datalevin (docs/DATALEVIN.md). It is read
  once at boot by `config/runtime.exs` into `config :sukhi_fedi, :store`;
  nothing else looks at the environment. `SukhiFedi.Store.Adapter` is the one
  module that acts on the answer — everything above it still calls
  `SukhiFedi.Repo`.
  """

  @spec kind() :: :postgres | :datalevin
  def kind, do: Application.get_env(:sukhi_fedi, :store, :postgres)

  @spec datalevin?() :: boolean()
  def datalevin?, do: kind() == :datalevin
end

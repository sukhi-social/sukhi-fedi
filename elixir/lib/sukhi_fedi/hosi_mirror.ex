# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HosiMirror do
  @moduledoc """
  hosigraph beside the store: the people and posts that are new in `SukhiFedi.Repo` are copied into
  it, a little after (`hosi_store/`, `SukhiHosi.Tail`). Like `SukhiFedi.Graph.Local` it follows the
  store and never changes a path that writes to it, so a failure here is logged and does not reach
  a user. Nothing reads from hosigraph yet.

  Off by default, and in two ways: the code is compiled in only when the build is asked for it
  (`SUKHI_HOSI=1`, see `mix.exs`), and it starts only when `SUKHI_HOSI_MIRROR=1`. `SUKHI_HOSI_DIR`
  is where hosigraph keeps its files (default `<DATALEVIN_DIR>/hosi`), `DATALEVIN_BIN` the `dtlv` it
  runs on.
  """

  @doc "Is it compiled in, and asked for?"
  @spec enabled?() :: boolean()
  def enabled?,
    do: Application.get_env(:sukhi_fedi, :hosi_mirror, false) == true and Code.ensure_loaded?(SukhiHosi.Tail)

  @doc "Children for the application's supervisor; none when off."
  @spec children() :: [module()]
  def children, do: if(enabled?(), do: [SukhiFedi.HosiMirror.Server], else: [])
end

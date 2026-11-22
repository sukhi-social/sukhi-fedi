# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HosiMirror do
  @moduledoc """
  hosigraph beside the store: the people and posts that are new in `SukhiFedi.Repo` are copied into
  it, a little after (`hosi_store/`, `SukhiHosi.Tail`). It follows the store and never changes a
  path that writes to it, so a failure here is logged and does not reach a user. What is on screen still comes from the store; hosigraph is read only to be compared
  with it (`shadow/3`).

  Off by default, and in two ways: the code is compiled in only when the build is asked for it
  (`SUKHI_HOSI=1`, see `mix.exs`), and it starts only when `SUKHI_HOSI_MIRROR=1`. `SUKHI_HOSI_DIR`
  is where hosigraph keeps its files (default `<DATALEVIN_DIR>/hosi`), `DATALEVIN_BIN` the `dtlv` it
  runs on. `SUKHI_HOSI_SHADOW=1` on top of that asks hosigraph the like view too (`shadow/3`).
  """

  @doc "Is it compiled in, and asked for?"
  @spec enabled?() :: boolean()
  def enabled?,
    do: Application.get_env(:sukhi_fedi, :hosi_mirror, false) == true and Code.ensure_loaded?(SukhiHosi.Tail)

  @doc """
  Hand over `answer`, the store's, for a read that hosigraph can answer too (`kind` and `args` say
  which, as `Notes` was called). When asked for (`SUKHI_HOSI_SHADOW`), the mirror compares them a
  little later in its own process and logs when they differ; this call only leaves a note and
  returns, and `answer` comes back as it is whatever happens to the note.
  """
  @spec shadow(answer, atom(), list()) :: answer when answer: term()
  def shadow(answer, kind, args) do
    if Application.get_env(:sukhi_fedi, :hosi_shadow, false) == true and enabled?() do
      server().shadow(kind, args, answer)
    end

    answer
  rescue
    _ -> answer
  catch
    _kind, _reason -> answer
  end

  # not written as a call: the module is there only in a build that has hosigraph, and the compiler
  # would say so in the one that has not
  defp server, do: Module.concat(__MODULE__, Server)

  @doc "Children for the application's supervisor; none when off."
  @spec children() :: [module()]
  def children, do: if(enabled?(), do: [SukhiFedi.HosiMirror.Server], else: [])
end

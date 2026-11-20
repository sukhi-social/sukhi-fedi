# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Mentions do
  @moduledoc """
  Who a post's text names. `extract/2` reads the plain text a person wrote (not the html it becomes)
  and gives back the ids of the actors it knows, once each, in the order they are first named; that
  is what `Notes.post` takes as `mentions:`.

  `@name` is one of ours, `@name@host` is the one of that host. A handle nobody here knows is left out
  (we cannot tell a remote person from a word; they are met when their post arrives). The `@` has to
  start a word: the one in an address (`me@x.org`), in a link (`/@bob`), or a second one (`@@bob`) is
  not a mention.
  """

  alias SukhiHosi.Actors

  @handle ~r/(?<![\w@\/.])@([A-Za-z0-9_]+)(?:@([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?))?/u

  def extract(db, text) when is_binary(text) do
    @handle
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [name | host] -> Actors.find_handle(db, name, List.first(host)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end

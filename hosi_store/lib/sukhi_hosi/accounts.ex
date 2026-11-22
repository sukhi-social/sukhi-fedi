# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Accounts do
  @moduledoc """
  Taking an account away. What an account owns is told by attributes that point at it, so
  deleting is one `erase` that names those attributes, not a walk over tables.

  Owned: the account itself, its posts, the outbox lines and boosts it caused, and the follows
  it is in on either side, and the notifications it has or caused. Then what hangs off its posts: boosts of them, outbox lines about them.
  Likes it gave are taken off other people's posts first, since a like is its own doing.
  What other people wrote stays.
  """

  alias SukhiHosi.Store

  @by_owner [:"object/attributed-to", :"outbox/actor", :"activity/actor", :"follow/follower", :"follow/followee",
               :"notification/recipient", :"notification/from"]
  @on_its_objects [:"outbox/object", :"activity/object", :"notification/note"]

  @doc """
  Take the likes off, hide the account's things at once, then let their bytes leave the disk
  (`clean`). Returns what `erase` answered. If it stops half way, call it again: each step looks
  at what is there now.
  """
  def erase(db, account) do
    liked =
      db |> Store.rows("[:find ?n :in $ ?a :where [?n :object/liked-by ?a]]", [[:scalar, account]]) |> List.flatten()

    if liked != [] do
      {:ok, _} = Hosi.write(db, Enum.map(liked, &[:delete, &1, :"object/liked-by", [:ref, account]]))
    end

    notes =
      db |> Store.rows("[:find ?n :in $ ?a :where [?n :object/attributed-to ?a]]", [[:scalar, account]]) |> List.flatten()

    erasures =
      [[:ids, [account]], [:"owned-by", @by_owner, [account]]] ++
        if(notes == [], do: [], else: [[:"owned-by", @on_its_objects, notes]])

    with {:ok, answer} <- Hosi.erase(db, erasures),
         {:ok, _} <- Hosi.clean(db) do
      {:ok, answer}
    end
  end
end

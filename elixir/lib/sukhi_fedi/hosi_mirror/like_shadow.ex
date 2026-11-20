# SPDX-License-Identifier: AGPL-3.0-or-later
if Code.ensure_loaded?(SukhiHosi.Notes) do
  defmodule SukhiFedi.HosiMirror.LikeShadow do
    @moduledoc """
    The like view (what a status shows: how many favourited it, and whether the viewer did) asked
    of hosigraph, and held against what the store answered. Run by `SukhiFedi.HosiMirror.Server`,
    so hosigraph is read in the one process that writes it.

    hosigraph is a little behind the store (a favourite waits for its post; a taken-back one waits
    for the sweep), so a difference right after a favourite is not a fault. What is worth a look is
    one that stays, or a post hosigraph does not have at all.

    A log line carries the kind, how many posts differ, which way, and a hash of the question:
    never the ids, which are people's posts.
    """

    import Ecto.Query

    require Logger

    alias SukhiFedi.Repo
    alias SukhiFedi.Schema.{Account, Note}
    alias SukhiHosi.{Copy, Notes}

    @doc """
    `kind` and `args` are how `SukhiFedi.Notes` was called (`:favourites` with `[note_ids]`,
    `:favourited` with `[account_id, note_ids]`); `answer` is what it returned. Returns `:ok`.
    """
    def compare(db, _domain, :favourites, [note_ids] = args, answer) do
      store = Map.new(answer, fn {id, %{favourites: n}} -> {id, n} end)
      report(:favourites, args, store, view(db, note_ids, nil), & &1.count)
    end

    # nobody is looking: every flag is false on both sides
    def compare(_db, _domain, :favourited, [nil, _note_ids], _answer), do: :ok

    def compare(db, domain, :favourited, [account_id, note_ids] = args, answer) do
      store = Map.new(answer, fn {id, %{favourited: yes?}} -> {id, yes?} end)
      report(:favourited, args, store, view(db, note_ids, viewer_iri(domain, account_id)), & &1.mine)
    end

    # note id => what hosigraph shows, for the posts it has
    defp view(db, note_ids, viewer) do
      iris = Map.new(Repo.all(from n in Note, where: n.id in ^note_ids and not is_nil(n.ap_id), select: {n.id, n.ap_id}))
      shown = Notes.like_view(db, Map.values(iris), viewer)
      for {id, iri} <- iris, Map.has_key?(shown, iri), into: %{}, do: {id, Map.fetch!(shown, iri)}
    end

    defp viewer_iri(domain, account_id) do
      case Repo.get(Account, account_id) do
        %Account{} = a -> Copy.iri_of(domain, a.username, a.domain, a.actor_uri)
        nil -> nil
      end
    end

    defp report(kind, args, store, shown, pick) do
      {here, absent} = Enum.split_with(store, fn {id, _} -> Map.has_key?(shown, id) end)
      differ = for {id, v} <- here, pick.(Map.fetch!(shown, id)) != v, do: {v, pick.(Map.fetch!(shown, id))}
      higher = Enum.count(differ, fn {was, now} -> now > was end)

      line =
        "like shadow (#{kind}): #{length(differ)} of #{map_size(store)} posts differ " <>
          "(hosigraph higher #{higher}, lower #{length(differ) - higher}), " <>
          "#{length(absent)} not in hosigraph, question hash #{:erlang.phash2(args)}"

      cond do
        differ != [] -> Logger.warning(line)
        absent != [] -> Logger.info(line)
        true -> :ok
      end

      :ok
    end
  end
end

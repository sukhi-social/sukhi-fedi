# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Timelines do
  @moduledoc """
  `SukhiFedi.Timelines` over the views: the home, public and tag queries and their gates.

  Lists, blocks and mutes are not ported: the id lists they produce come in as options.
  Preloads, boost wrappers' accounts, caching and `with_refs` are left out.

    * `:hidden` – authors blocked, muted or silenced
    * `:excluded` – members of exclusive lists
    * `:gates` – `%{only_media:, hide_boosts:, hide_sensitive:, hide_replies:, replies_to_me:}`
    * `:keywords` – `[{member_ids, keyword}]`
    * `:reply_here` – the `like` pattern of a post on this server
    * `:max_id`, `:since_id`, `:min_id` – API IDs (a boost row's is the boost's own). Rows are
      ordered by hosigraph's integer (a time and a counter), never by the text of an API ID.
  """
  import Ecto.Query
  import Bitwise
  alias CoreViews.{Boost, Follow, Ids, Note, Records, Repo}

  @epoch_ms 1_767_225_600_000
  @counter_bits 21
  # most places in one step of the index walk: Datalevin fails to compile `id in ^ids` with another
  # condition at 10,240 ids, and a read gives up after 5 s
  @step 2_000

  # `SukhiFedi.Store.Ids`
  def encode(unix_ms, counter),
    do: bsl(max(unix_ms - @epoch_ms, 0), @counter_bits) ||| rem(counter, bsl(1, @counter_bits))

  def to_datetime(id), do: DateTime.from_unix!(bsr(id, @counter_bits) + @epoch_ms, :millisecond)

  def home(account_id, actor_uri, opts \\ []),
    do: paged(opts, &home_page(account_id, actor_uri, &1))

  defp home_page(account_id, actor_uri, opts) do
    limit = Map.get(opts, :limit, 20)
    hidden = Map.get(opts, :hidden, [])
    excluded = Map.get(opts, :excluded, [])
    gates = gates(opts)

    following = following(actor_uri)
    mine = if opts[:exclude_self], do: [], else: [account_id]
    note_ids = mine ++ (following -- hidden)
    # What sukhi's comments ask for. `SukhiFedi.Timelines` has `a -- (b -- (c -- d))`, which does
    # not drop `hide_boosts` or hidden boosters (`--` is right-associative).
    boost_ids = mine ++ (((following -- excluded) -- gates.hide_boosts) -- hidden)

    notes =
      newest(Note, note_ids, limit, opts, fn ids ->
        Note
        |> where([n], n.id in ^ids)
        |> gate(excluded, fn q, m ->
          pattern = Map.fetch!(opts, :reply_here)
          where(q, [n], n.account_id not in ^m or like(n.in_reply_to_ap_id, ^pattern))
        end)
        |> where([n], n.visibility in ["public", "unlisted", "followers"])
        |> gate(gates.only_media, fn q, m ->
          where(q, [n], n.account_id not in ^m or not is_nil(n.media_ids))
        end)
        |> gate(gates.hide_sensitive, fn q, m ->
          where(q, [n], n.account_id not in ^m or (n.sensitive == false and is_nil(n.cw)))
        end)
        |> gate(gates.hide_replies, fn q, m ->
          where(q, [n], n.account_id not in ^m or is_nil(n.in_reply_to_ap_id))
        end)
        |> gate(gates.replies_to_me, fn q, m ->
          pattern = Map.fetch!(opts, :reply_here)

          where(
            q,
            [n],
            n.account_id not in ^m or is_nil(n.in_reply_to_ap_id) or
              like(n.in_reply_to_ap_id, ^pattern)
          )
        end)
        |> keyword_gates(Map.get(opts, :keywords, []))
        |> only_media(opts[:only_media])
        |> hide_sensitive(opts[:hide_sensitive])
        |> page(opts)
        |> Repo.all()
      end)

    boosts = if opts[:hide_boosts], do: [], else: boost_page(boost_ids, limit, opts, hidden)

    (notes ++ boosts) |> Enum.sort_by(& &1.id, :desc) |> Enum.take(limit)
  end

  def following(actor_uri) do
    Repo.all(
      from f in Follow,
        where: f.follower_uri == ^actor_uri and f.state == "accepted",
        select: f.followee_id
    )
  end

  @doc "Boosts as `%{id: cursor, api_id:, boost_id:, booster_id:, note:}`."
  def boosts(account_ids, limit, opts, hidden),
    do: paged(opts, &boost_page(account_ids, limit, &1, hidden))

  defp boost_page(account_ids, limit, opts, hidden) do
    newest(Boost, account_ids, limit, opts, fn ids ->
      from(b in Boost,
        join: n in Note,
        on: n.id == b.note_id,
        where: b.id in ^ids,
        where: n.visibility in ["public", "unlisted"],
        order_by: [desc: b.created_at],
        limit: ^limit,
        select: %{
          boost_id: b.id,
          api_id: b.api_id,
          created_at: b.created_at,
          booster_id: b.account_id,
          note: n
        }
      )
      |> gate(hidden, fn q, m -> where(q, [_b, n], n.account_id not in ^m) end)
      |> boost_bounds(opts)
      |> Repo.all()
    end)
    |> Enum.map(fn row ->
      Map.put(row, :id, encode(DateTime.to_unix(row.created_at, :millisecond), row.boost_id))
    end)
    |> exact(opts[:max_id], &</2)
    |> exact(opts[:since_id] || opts[:min_id], &>/2)
  end

  def public(opts \\ []), do: paged(opts, &public_page/1)

  defp public_page(opts) do
    Note
    |> where([n], n.visibility == "public")
    |> where([n], n.account_id not in ^Map.get(opts, :hidden, []))
    |> local_only(Map.get(opts, :local, true))
    |> page(opts)
    |> only_media(opts[:only_media])
    |> hide_sensitive(opts[:hide_sensitive])
    |> Repo.all()
  end

  def tag(hashtag, opts \\ []), do: paged(opts, &tag_page(hashtag, &1))

  defp tag_page(hashtag, opts) do
    name = hashtag |> String.trim_leading("#") |> String.downcase()

    Note
    |> where([n], ^name in n.tags and n.visibility == "public")
    |> local_only(Map.get(opts, :local, true))
    |> only_media(opts[:only_media])
    |> hide_sensitive(opts[:hide_sensitive])
    |> page(opts)
    |> Repo.all()
  end

  @doc """
  The place in a timeline an API ID names: a note's integer id, or for a boost the cursor made
  from its time. A local record that is gone (an undone boost) still says its time in its `s1` ID;
  a remote one does not, and then there is no place: `:error`.
  """
  def cursor(api_id) do
    case Records.resolve(api_id) do
      %Boost{id: id, created_at: at} ->
        {:ok, encode(DateTime.to_unix(at, :millisecond), id)}

      %{id: id} ->
        {:ok, id}

      nil ->
        case Ids.decode_s1(Ids.normalize(api_id)) do
          {:ok, %{unix_ms: ms}} -> {:ok, encode(ms, 0)}
          :error -> :error
        end
    end
  end

  # the page after places given as API IDs; an ID that names no place gives an empty page
  defp paged(opts, page) do
    [:max_id, :since_id, :min_id]
    |> Enum.reduce_while(Map.new(opts), fn key, opts ->
      case opts[key] && cursor(opts[key]) do
        nil -> {:cont, opts}
        {:ok, place} -> {:cont, Map.put(opts, key, place)}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> []
      opts -> page.(opts)
    end
  end

  # sukhi's `EXISTS (SELECT 1 FROM note_media ..)`: the note has an attachment
  defp only_media(query, true), do: where(query, [n], not is_nil(n.media_ids))
  defp only_media(query, _), do: query

  defp hide_sensitive(query, true),
    do: where(query, [n], n.sensitive == false and is_nil(n.cw))

  defp hide_sensitive(query, _), do: query

  defp local_only(query, true), do: where(query, [n], is_nil(n.domain))
  defp local_only(query, _), do: query

  defp keyword_gates(query, gates) do
    Enum.reduce(gates, query, fn {members, keyword}, q ->
      pattern = "%" <> String.downcase(keyword) <> "%"
      tag = keyword |> String.trim_leading("#") |> String.downcase()

      where(
        q,
        [n],
        n.account_id not in ^members or is_nil(n.content) or
          like(fragment("lower(?)", n.content), ^pattern) or ^tag in n.tags
      )
    end)
  end

  defp gates(opts) do
    Map.merge(
      %{only_media: [], hide_boosts: [], hide_sensitive: [], hide_replies: [], replies_to_me: []},
      Map.get(opts, :gates, %{})
    )
  end

  defp gate(query, [], _fun), do: query
  defp gate(query, ids, fun), do: fun.(query, ids)

  defp page(query, opts) do
    query =
      Enum.reduce([:max_id, :since_id, :min_id], query, fn key, q ->
        case {key, opts[key]} do
          {_, nil} -> q
          {:max_id, id} -> where(q, [n], n.id < ^id)
          {_, id} -> where(q, [n], n.id > ^id)
        end
      end)

    query |> order_by([n], desc: n.id) |> limit(^Map.get(opts, :limit, 20))
  end

  defp boost_bounds(query, opts) do
    query =
      case opts[:max_id] do
        nil -> query
        id -> where(query, [b], b.created_at <= ^to_datetime(id))
      end

    case opts[:since_id] || opts[:min_id] do
      nil -> query
      id -> where(query, [b], b.created_at >= ^to_datetime(id))
    end
  end

  defp exact(rows, nil, _cmp), do: rows
  defp exact(rows, cursor, cmp), do: Enum.filter(rows, &cmp.(&1.id, cursor))

  # `SukhiFedi.Timelines.newest/5`: candidates from the (account, created_at) index while the gates
  # leave fewer than asked. sukhi asks again from the top for twice as many; this goes on from the
  # last place, in steps that stop growing.
  defp newest(_view, [], _limit, _opts, _run), do: []

  defp newest(view, account_ids, limit, opts, run) do
    place =
      case opts[:max_id] do
        nil -> nil
        id -> %{at: bound(id, 1), id: 9_223_372_036_854_775_807}
      end

    floor =
      case opts[:since_id] || opts[:min_id] do
        nil -> nil
        id -> bound(id, -1)
      end

    walk(view, account_ids, limit, run, place, floor, max(limit * 2, 40), [])
  end

  defp walk(view, account_ids, limit, run, place, floor, n, found) do
    places = Repo.highest_in(view, {:account_id, :created_at}, account_ids, n, after: place)
    found = found ++ run.(Enum.map(places, & &1.id))

    cond do
      length(found) >= limit ->
        found

      length(places) < n ->
        found

      floor != nil and DateTime.compare(List.last(places).at, floor) != :gt ->
        found

      true ->
        walk(view, account_ids, limit, run, List.last(places), floor, min(n * 2, @step), found)
    end
  end

  defp bound(id, seconds),
    do: id |> to_datetime() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
end

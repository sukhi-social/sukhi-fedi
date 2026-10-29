# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.Serve do
  @moduledoc """
  The origin's answer to a pull (`GET /pull/v1/stream`, docs/PULL_FEDERATION.md §4).

  The request says, for each of our actors the requester follows, how far
  it has applied (`c[]=<seq>@<actor uri>`). The answer is the log rows after
  that, in per-actor order, one page at a time. All in three queries for the
  whole page — authorisation, rows, heads — whatever the number of actors.

  Authorisation is *whose follower is asking*: the signer's host must have an
  accepted follower of the actor. A host that follows nobody of ours gets
  nothing, so the log is no more public than the push it replaces. The
  signature itself was checked at the edge (`Web.SignedRequest`).
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiShared.PullStats

  @max_cursors 64
  @page_items 100
  @first_window 20

  def page_items, do: @page_items

  @doc """
  Parse the `c` entries of a query string into `{actor_uri, after_seq}`.
  Entries that do not parse are skipped; more than `#{@max_cursors}` are cut.
  """
  @spec parse_cursors(String.t()) :: [{String.t(), non_neg_integer()}]
  def parse_cursors(query_string) when is_binary(query_string) do
    query_string
    |> URI.query_decoder()
    |> Enum.flat_map(fn
      {key, value} when key in ["c", "c[]"] ->
        with [seq, uri] <- String.split(value, "@", parts: 2),
             {n, ""} <- Integer.parse(seq),
             true <- n >= 0 and String.starts_with?(uri, "https://") do
          [{uri, n}]
        else
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(@max_cursors)
  end

  @doc """
  The page for `signer_host`. `{:ok, page}` or `{:error, :denied}` when none
  of the asked-for actors is ours and followed by that host.
  """
  @spec page(String.t(), [{String.t(), non_neg_integer()}], String.t()) ::
          {:ok, map()} | {:error, :denied}
  def page(signer_host, cursors, domain) do
    prefix = "https://#{domain}/users/"

    asked =
      for {uri, n} <- cursors,
          String.starts_with?(uri, prefix),
          not String.contains?(String.replace_prefix(uri, prefix, ""), "/"),
          do: {String.replace_prefix(uri, prefix, ""), uri, n}

    case authorised(signer_host, asked) do
      [] ->
        PullStats.bump("stream_denied", host: signer_host)
        {:error, :denied}

      allowed ->
        {:ok, build(allowed)}
    end
  end

  # [{account_id, actor_uri, after_seq}] for the asked actors this host
  # follows. One query.
  defp authorised(_host, []), do: []

  defp authorised(host, asked) do
    names = Enum.map(asked, &elem(&1, 0))

    ids =
      from(a in "accounts",
        where: is_nil(a.domain) and a.username in ^names,
        select: {a.username, a.id}
      )
      |> Repo.all()
      |> Map.new()

    # Of those, the ones some follower on `host` has an accepted follow of.
    followed =
      from(f in "follows",
        where:
          f.followee_id in ^Map.values(ids) and f.state == "accepted" and
            (like(fragment("lower(?)", f.follower_uri), ^"https://#{host}/%") or
               like(fragment("lower(?)", f.follower_uri), ^"http://#{host}/%")),
        distinct: true,
        select: f.followee_id
      )
      |> Repo.all()
      |> MapSet.new()

    for {name, uri, n} <- asked,
        id = ids[name],
        MapSet.member?(followed, id),
        do: {id, uri, n}
  end

  defp build(allowed) do
    ids = Enum.map(allowed, &elem(&1, 0))

    heads =
      from(h in "pull_heads",
        where: h.account_id in ^ids,
        select: {h.account_id, h.seq, h.pruned_through}
      )
      |> Repo.all()
      |> Map.new(fn {id, seq, pruned} -> {id, {seq, pruned}} end)

    # Where each actor's answer starts: after the cursor; after the prune
    # line if the cursor is behind it (a resync); and for an actor the
    # requester has never pulled (cursor 0), only the newest few rows.
    starts =
      for {id, uri, n} <- allowed do
        {head, pruned} = Map.get(heads, id, {0, 0})
        resync? = n > 0 and n < pruned
        first? = n == 0
        after_seq = if first?, do: max(pruned, head - @first_window), else: max(n, pruned)
        {id, uri, after_seq, resync?}
      end

    # One small query per actor, each a range on (account_id, seq); the page
    # is cut to its size across them, in account order.
    rows =
      starts
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {id, _uri, after_seq, _} ->
        from(l in "pull_log",
          where: l.account_id == ^id and l.seq > ^after_seq,
          order_by: l.seq,
          limit: ^(@page_items + 1),
          select: [l.account_id, l.seq, type(l.body, :map)]
        )
        |> Repo.all()
      end)
      |> Enum.take(@page_items + 1)

    uri_of = Map.new(allowed, fn {id, uri, _} -> {id, uri} end)
    {taken, rest} = Enum.split(rows, @page_items)

    items =
      for [id, seq, body] <- taken,
          do: %{"actor" => uri_of[id], "seq" => seq, "activity" => body}

    PullStats.bump("activities_served", n: length(items))

    %{
      "type" => "PullPage",
      "items" => items,
      "heads" => Map.new(heads, fn {id, {seq, _}} -> {uri_of[id], seq} end),
      "more" => rest != [],
      "resync" => for({_, uri, _, true} <- starts, do: uri)
    }
  end
end

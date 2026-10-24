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

    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.id, a.username FROM accounts a
        WHERE a.domain IS NULL AND a.username = ANY($1)
          AND EXISTS (SELECT 1 FROM follows f WHERE f.followee_id = a.id AND f.state = 'accepted'
                      AND lower(split_part(f.follower_uri, '/', 3)) = $2)
        """,
        [names, host]
      )

    ids = Map.new(rows, fn [id, name] -> {name, id} end)

    for {name, uri, n} <- asked, id = ids[name], do: {id, uri, n}
  end

  defp build(allowed) do
    ids = Enum.map(allowed, &elem(&1, 0))

    heads =
      Repo.query!(
        "SELECT account_id, seq, pruned_through FROM pull_heads WHERE account_id = ANY($1)",
        [ids]
      ).rows
      |> Map.new(fn [id, seq, pruned] -> {id, {seq, pruned}} end)

    # Where each actor's answer starts: after the cursor; after the prune
    # line if the cursor is behind it (a resync); and for an actor the
    # requester has never pulled (cursor 0), only the newest few rows.
    starts =
      for {id, uri, n} <- allowed do
        {head, pruned} = Map.get(heads, id, {0, 0})
        resync? = n > 0 and n < pruned
        first? = n == 0
        from = if first?, do: max(pruned, head - @first_window), else: max(n, pruned)
        {id, uri, from, resync?}
      end

    %{rows: rows} =
      Repo.query!(
        """
        SELECT l.account_id, l.seq, l.body
        FROM pull_log l JOIN unnest($1::bigint[], $2::bigint[]) AS c(id, after_seq)
          ON l.account_id = c.id AND l.seq > c.after_seq
        ORDER BY l.account_id, l.seq
        LIMIT $3
        """,
        [Enum.map(starts, &elem(&1, 0)), Enum.map(starts, &elem(&1, 2)), @page_items + 1]
      )

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

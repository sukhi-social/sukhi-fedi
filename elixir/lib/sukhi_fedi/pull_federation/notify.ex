# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.Notify do
  @moduledoc """
  The receiving end of a Pull Federation notification
  (`POST /pull/v1/notify`, docs/PULL_FEDERATION.md §3).

  A notification is a hint, never data: it says "origin X has activity up to
  sequence N for these actors". It is untrusted until proven otherwise, so
  the order here is: signature (done by the controller, once, at the edge)
  → the signer is the origin it names → shape → only actors a local user
  follows → rate floor → remember it. Nothing in the body is ever executed;
  the activities themselves arrive later, through `Puller` and `AP.Ingest`.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiShared.{PeerCapabilities, PullStats}

  @max_heads 1_000
  @max_uri 512
  @max_seq 9_007_199_254_740_991

  # One origin may notify at most this often. An honest sender coalesces to
  # about one per second per host; more than this is a loop or an attack.
  @floor_hits 5
  @floor_window_ms 1_000

  @doc """
  Shape-check a decoded body. Returns `{:ok, origin, [{actor_uri, seq}]}`.
  Every actor URI must live on the origin the sender claims, so an origin
  can only talk about its own actors.
  """
  @spec parse(term()) :: {:ok, String.t(), [{String.t(), pos_integer()}]} | {:error, :bad_shape}
  def parse(%{"type" => "PullNotification", "origin" => origin, "heads" => heads})
      when is_binary(origin) and is_map(heads) and map_size(heads) > 0 and
             map_size(heads) <= @max_heads do
    origin = String.downcase(origin)

    pairs =
      Enum.reduce_while(heads, [], fn
        {uri, seq}, acc
        when is_binary(uri) and byte_size(uri) <= @max_uri and is_integer(seq) and seq > 0 and
               seq <= @max_seq ->
          if PeerCapabilities.host_of(uri) == origin and String.starts_with?(uri, "https://"),
            do: {:cont, [{uri, seq} | acc]},
            else: {:halt, :bad}

        _, _ ->
          {:halt, :bad}
      end)

    if pairs == :bad, do: {:error, :bad_shape}, else: {:ok, origin, pairs}
  end

  def parse(_), do: {:error, :bad_shape}

  @doc """
  Remember what `origin` told us. Returns `{:ok, n}` (n heads newer than what
  we already applied and followed by a local user), `{:dropped, reason}`
  (`:rate_floor` | `:nothing_wanted`).
  """
  @spec accept(String.t(), [{String.t(), pos_integer()}], DateTime.t()) ::
          {:ok, non_neg_integer()} | {:dropped, :rate_floor | :nothing_wanted}
  def accept(origin, heads, now \\ DateTime.utc_now()) do
    case Hammer.check_rate("pull_notify:#{origin}", @floor_window_ms, @floor_hits) do
      {:deny, _} ->
        PullStats.bump("notify_dropped", host: origin)
        {:dropped, :rate_floor}

      {:allow, _} ->
        case remember(origin, heads, now) do
          0 ->
            PullStats.bump("notify_dropped", host: origin)
            {:dropped, :nothing_wanted}

          n ->
            PullStats.bump("notify_received", host: origin)
            {:ok, n}
        end
    end
  end

  # Keep the heads for actors a local user follows (an accepted follow of the
  # shadow row) and that are ahead of our cursor, and upsert them. Returns how
  # many rows that was. A few small queries — the followed set, the cursors,
  # the writes — each on its own indexed key.
  defp remember(origin, heads, now) do
    uris = Enum.map(heads, &elem(&1, 0))

    followed =
      from(a in "accounts",
        join: f in "follows",
        on: f.followee_id == a.id and f.state == "accepted",
        where: a.actor_uri in ^uris and not is_nil(a.domain),
        distinct: true,
        select: a.actor_uri
      )
      |> Repo.all()
      |> MapSet.new()

    cursors =
      from(c in "pull_cursors", where: c.actor_uri in ^uris, select: {c.actor_uri, c.seq})
      |> Repo.all()
      |> Map.new()

    keep =
      for {uri, seq} <- heads,
          MapSet.member?(followed, uri),
          seq > Map.get(cursors, uri, 0),
          do: {uri, seq}

    at = DateTime.to_naive(now)

    if keep != [] do
      Repo.insert_all(
        "pull_pending",
        Enum.map(keep, fn {uri, seq} ->
          %{host: origin, actor_uri: uri, head: seq, received_at: at}
        end),
        on_conflict: :nothing,
        conflict_target: [:host, :actor_uri]
      )

      for {uri, seq} <- keep do
        from(p in "pull_pending", where: p.host == ^origin and p.actor_uri == ^uri and p.head < ^seq)
        |> Repo.update_all(set: [head: seq])

        from(p in "pull_pending", where: p.host == ^origin and p.actor_uri == ^uri)
        |> Repo.update_all(set: [received_at: at])
      end
    end

    length(keep)
  end

  @doc "Hosts that have something pending, oldest first. For the scheduler."
  @spec pending_hosts(non_neg_integer()) :: [String.t()]
  def pending_hosts(limit) do
    from(p in "pull_pending",
      group_by: p.host,
      order_by: min(p.received_at),
      limit: ^limit,
      select: p.host
    )
    |> Repo.all()
  end
end

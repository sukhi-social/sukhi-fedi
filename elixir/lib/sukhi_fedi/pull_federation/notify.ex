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

  # One statement: keep the heads for actors a local user follows (an
  # accepted follow of the shadow row) and that are ahead of our cursor, and
  # upsert them. Returns how many rows that was.
  defp remember(origin, heads, now) do
    uris = Enum.map(heads, &elem(&1, 0))
    seqs = Enum.map(heads, &elem(&1, 1))

    %{num_rows: n} =
      Repo.query!(
        """
        INSERT INTO pull_pending (host, actor_uri, head, received_at)
        SELECT $1, h.uri, h.seq, $4
        FROM unnest($2::text[], $3::bigint[]) AS h(uri, seq)
        WHERE EXISTS (
          SELECT 1 FROM accounts a JOIN follows f ON f.followee_id = a.id AND f.state = 'accepted'
          WHERE a.actor_uri = h.uri AND a.domain IS NOT NULL)
          AND h.seq > COALESCE((SELECT c.seq FROM pull_cursors c WHERE c.actor_uri = h.uri), 0)
        ON CONFLICT (host, actor_uri) DO UPDATE SET
          head = GREATEST(pull_pending.head, EXCLUDED.head), received_at = EXCLUDED.received_at
        """,
        [origin, uris, seqs, DateTime.to_naive(now)]
      )

    n
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

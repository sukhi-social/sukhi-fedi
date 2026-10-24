# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.Pull do
  @moduledoc """
  One pull from one origin host: ask for what changed, apply it, move the
  cursors, and report how it went so `Puller` can schedule the next one.

  The request carries our cursor for every pending actor of that host (up to
  64): one signed GET per host, not one per actor, and the answer holds only
  what is newer. Activities are not trusted because they arrived in a
  response: each goes through `AP.Ingest` exactly like an inbox activity, with
  the origin host as the signer, so instance policy, the FEP-8b32 proof and
  the "actor lives on the signer's host" binding all apply unchanged.
  A cursor moves past an activity we refused too — otherwise one bad
  activity would block its actor for ever — and the refusal is counted.
  """

  require Logger

  alias SukhiFedi.AP.Ingest
  alias SukhiFedi.Fedi.Fetcher
  alias SukhiFedi.Repo
  alias SukhiShared.{PeerCapabilities, PullStats}

  @max_cursors 64

  @type outcome ::
          :idle
          | {:ok, %{applied: non_neg_integer(), more: boolean()}}
          | {:declined, pos_integer()}
          | {:error, term()}

  @spec run(String.t()) :: outcome()
  def run(host) do
    case pending(host) do
      [] ->
        :idle

      asked ->
        started = System.monotonic_time(:millisecond)
        result = fetch(host, asked)
        ms = System.monotonic_time(:millisecond) - started

        case result do
          {:ok, page} ->
            PullStats.bump("pull_ok", ms: ms, host: host)
            apply_page(host, asked, page)

          {:declined, secs} ->
            PullStats.bump("pull_declined", host: host)
            {:declined, secs}

          {:error, reason} ->
            PullStats.bump("pull_failed", host: host)
            {:error, reason}
        end
    end
  end

  # [{actor_uri, head, cursor}] — heads ahead of what we have applied.
  defp pending(host) do
    Repo.query!(
      """
      SELECT p.actor_uri, p.head, COALESCE(c.seq, 0)
      FROM pull_pending p LEFT JOIN pull_cursors c ON c.actor_uri = p.actor_uri
      WHERE p.host = $1 ORDER BY p.received_at LIMIT $2
      """,
      [host, @max_cursors]
    ).rows
    |> Enum.map(fn [uri, head, cursor] -> {uri, head, cursor} end)
    |> drop_satisfied(host)
  end

  # Pending rows we have since caught up with go away; the rest are asked.
  defp drop_satisfied(rows, host) do
    {done, todo} = Enum.split_with(rows, fn {_, head, cursor} -> head <= cursor end)

    if done != [] do
      Repo.query!("DELETE FROM pull_pending WHERE host = $1 AND actor_uri = ANY($2)", [
        host,
        Enum.map(done, &elem(&1, 0))
      ])
    end

    todo
  end

  defp fetch(host, asked) do
    query =
      asked
      |> Enum.map(fn {uri, _head, cursor} -> {"c[]", "#{cursor}@#{uri}"} end)
      |> URI.encode_query()

    url = SukhiFedi.PullFederation.stream_base(host) <> "?" <> query

    case Fetcher.get_raw(url, SukhiFedi.Accounts.signing_identity()) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, %{"type" => "PullPage", "items" => items} = page} when is_list(items) ->
            {:ok, page}

          _ ->
            {:error, :bad_page}
        end

      {:ok, %{status: status} = resp} when status in [429, 503] ->
        {:declined, retry_after(resp)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_page(host, asked, page) do
    asked_uris = MapSet.new(asked, &elem(&1, 0))
    items = page["items"]
    sign_as = SukhiFedi.Accounts.signing_identity()

    reached =
      Enum.reduce(items, %{}, fn item, acc ->
        case apply_item(host, asked_uris, item, sign_as) do
          {:ok, uri, seq} -> Map.update(acc, uri, seq, &max(&1, seq))
          :skip -> acc
        end
      end)

    more = page["more"] == true

    # When the origin has nothing more, everything it holds for an asked
    # actor is applied or retracted, so the cursor may rest at its head (a
    # retracted activity leaves a gap in the numbering, not a loss).
    reached =
      if more do
        reached
      else
        heads = if is_map(page["heads"]), do: page["heads"], else: %{}

        Enum.reduce(asked, reached, fn {uri, _, _}, acc ->
          case heads[uri] do
            n when is_integer(n) and n > 0 -> Map.update(acc, uri, n, &max(&1, n))
            _ -> acc
          end
        end)
      end

    resync = for uri <- List.wrap(page["resync"]), uri in asked_uris, do: uri
    if resync != [], do: PullStats.bump("resync", n: length(resync), host: host)

    advance(host, reached)
    {:ok, %{applied: length(items), more: more}}
  end

  # An item names the actor it belongs to and carries the activity. Both
  # must be on the host we asked and be the same actor, and the actor must
  # be one we asked about. Anything else is refused (and the cursor moves on).
  defp apply_item(
         host,
         asked_uris,
         %{"actor" => uri, "seq" => seq, "activity" => activity},
         sign_as
       )
       when is_binary(uri) and is_integer(seq) and is_map(activity) do
    cond do
      uri not in asked_uris ->
        :skip

      PeerCapabilities.host_of(uri) != host or activity["actor"] != uri ->
        PullStats.bump("activities_rejected", host: host)
        {:ok, uri, seq}

      true ->
        case Ingest.run(activity, host, sign_as: sign_as) do
          :accepted ->
            PullStats.bump("activities_applied", ms: lag_ms(activity), host: host)

          :suppressed ->
            PullStats.bump("activities_rejected", host: host)

          {:error, reason} ->
            Logger.info("pull #{host}: refused #{inspect(activity["id"])}: #{inspect(reason)}")
            PullStats.bump("activities_rejected", host: host)
        end

        {:ok, uri, seq}
    end
  end

  defp apply_item(_host, _asked, _item, _sign_as), do: :skip

  # Publish-to-apply lag, from the activity's own `published`. nil (no ms
  # added) when it is missing or in the future.
  defp lag_ms(%{"published" => published}) when is_binary(published) do
    with {:ok, at, _} <- DateTime.from_iso8601(published),
         lag when lag >= 0 <- DateTime.diff(DateTime.utc_now(), at, :millisecond) do
      lag
    else
      _ -> nil
    end
  end

  defp lag_ms(_), do: nil

  defp advance(_host, reached) when map_size(reached) == 0, do: :ok

  defp advance(host, reached) do
    uris = Map.keys(reached)
    seqs = Enum.map(uris, &Map.fetch!(reached, &1))

    Repo.query!(
      """
      INSERT INTO pull_cursors (actor_uri, host, seq, updated_at)
      SELECT u, $1, s, now() FROM unnest($2::text[], $3::bigint[]) AS t(u, s)
      ON CONFLICT (actor_uri) DO UPDATE SET seq = GREATEST(pull_cursors.seq, EXCLUDED.seq), updated_at = now()
      """,
      [host, uris, seqs]
    )

    Repo.query!(
      """
      DELETE FROM pull_pending p USING pull_cursors c
      WHERE p.host = $1 AND c.actor_uri = p.actor_uri AND p.head <= c.seq
      """,
      [host]
    )

    :ok
  end

  defp retry_after(%{headers: headers}) do
    value =
      case headers do
        %{"retry-after" => [v | _]} -> v
        %{"retry-after" => v} when is_binary(v) -> v
        _ -> nil
      end

    case value && Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> min(n, 3_600)
      _ -> 5
    end
  end
end

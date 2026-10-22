# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.RefetchActors do
  @moduledoc """
  Re-fetch every remote actor and re-upsert it, so fields we only started
  capturing recently — custom emoji in the name/bio — fill in on existing
  shadow rows.

  `RemoteAccounts.upsert_from_actor_json/1` updates in place keyed on
  `actor_uri`, so the numeric id and every follow edge stay put; this also
  refreshes display name / bio / avatar to the actor's current state.

  Fetch-first: an actor whose origin is gone or unreachable is left
  exactly as-is. Network-bound — one signed GET per remote account.

  Run on the live gateway (needs its Repo + federation fetch):

      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RefetchActors.run(:dry_run)'
      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RefetchActors.run(:execute)'
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.Federation.{ActorFetcher, RemoteAccounts}
  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  @spec run(:dry_run | :execute) :: map()
  def run(mode \\ :dry_run) do
    uris = remote_actor_uris()
    Logger.info("refetch_actors: #{length(uris)} remote actor(s), mode=#{mode}")

    summary =
      case mode do
        :dry_run ->
          for uri <- uris, do: Logger.info("  would refetch #{uri}")
          tally(List.duplicate(:would_refetch, length(uris)))

        :execute ->
          Progress.track("refetch_actors", mode, length(uris), "fetching", fn run ->
            {results, run} = Progress.map(run, uris, &refetch/1)
            {tally(results), run}
          end)
      end

    Logger.info("refetch_actors done: #{inspect(summary)}")
    Map.put(summary, :mode, mode)
  end

  @doc "actor_uris of every remote (shadow) account."
  def remote_actor_uris do
    from(a in Account,
      where: not is_nil(a.domain) and not is_nil(a.actor_uri),
      select: a.actor_uri,
      order_by: a.id
    )
    |> Repo.all()
  end

  defp refetch(uri) do
    case ActorFetcher.fetch(uri) do
      {:ok, json} ->
        case RemoteAccounts.upsert_from_actor_json(json, uri) do
          {:ok, _} ->
            :refetched

          {:error, reason} ->
            Logger.error("  upsert failed #{uri}: #{inspect(reason)}")
            :error
        end

      {:error, reason} ->
        Logger.warning("  skip #{uri}: fetch failed #{inspect(reason)}")
        :skipped
    end
  end

  defp tally(results) do
    Enum.reduce(results, %{}, fn r, acc -> Map.update(acc, r, 1, &(&1 + 1)) end)
  end
end

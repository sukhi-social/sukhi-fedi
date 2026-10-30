# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Stats do
  @moduledoc """
  Aggregate metrics for the admin dashboard.

  A single `dashboard/0` call rolls up accounts, statuses, federation
  known/blocked domains, and moderation queue counts. The result is
  kept for 30 seconds by `HotCache` — admin dashboards poll often but the
  numbers don't need to be second-fresh.
  """

  import Ecto.Query

  alias SukhiFedi.{HotCache, Repo}

  alias SukhiFedi.Schema.{
    Account,
    Follow,
    InstanceBlock,
    Note,
    OauthAccessToken,
    Report
  }

  @doc """
  Return a dashboard-shaped map. A call within 30 seconds of the last one
  gets the same map back; otherwise the aggregate queries run again.
  """
  @spec dashboard() :: map()
  def dashboard do
    HotCache.fetch(:stats_dashboard, HotCache.ttl(:stats_dashboard), &compute/0)
  end

  defp compute do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    minus_1d = DateTime.add(now, -1 * 86_400, :second)
    minus_7d = DateTime.add(now, -7 * 86_400, :second)
    minus_30d = DateTime.add(now, -30 * 86_400, :second)

    accounts_total = Repo.aggregate(Account, :count, :id)

    accounts_suspended =
      Repo.aggregate(from(a in Account, where: not is_nil(a.suspended_at)), :count, :id)

    accounts_admins =
      Repo.aggregate(from(a in Account, where: a.is_admin == true), :count, :id)

    active_7d = count_active_since(minus_7d)
    active_30d = count_active_since(minus_30d)

    statuses_total = Repo.aggregate(Note, :count, :id)

    statuses_last_24h =
      Repo.aggregate(from(n in Note, where: n.created_at > ^minus_1d), :count, :id)

    statuses_last_7d =
      Repo.aggregate(from(n in Note, where: n.created_at > ^minus_7d), :count, :id)

    known_domains = count_known_domains()

    blocked_domains = Repo.aggregate(InstanceBlock, :count, :id)

    open_reports =
      Repo.aggregate(from(r in Report, where: r.status == "open"), :count, :id)

    resolved_reports_7d =
      Repo.aggregate(
        from(r in Report,
          where: r.status == "resolved" and not is_nil(r.resolved_at) and r.resolved_at > ^minus_7d
        ),
        :count,
        :id
      )

    %{
      accounts: %{
        total: accounts_total,
        local: accounts_total,
        remote: 0,
        suspended: accounts_suspended,
        admins: accounts_admins,
        active_last_7d: active_7d,
        active_last_30d: active_30d
      },
      statuses: %{
        total: statuses_total,
        local: statuses_total,
        last_24h: statuses_last_24h,
        last_7d: statuses_last_7d
      },
      federation: %{
        known_domains: known_domains,
        blocked_domains: blocked_domains
      },
      moderation: %{
        open_reports: open_reports,
        resolved_reports_7d: resolved_reports_7d
      },
      generated_at: DateTime.to_iso8601(now)
    }
  end

  defp count_active_since(%DateTime{} = since) do
    # Distinct accounts that touched an access token recently (the OAuth
    # layer refreshes `last_used_at` on every `verify_bearer`).
    query =
      from t in OauthAccessToken,
        where: not is_nil(t.account_id) and not is_nil(t.last_used_at) and t.last_used_at > ^since,
        distinct: t.account_id,
        select: t.account_id

    Repo.aggregate(subquery(query), :count, :account_id)
  end

  defp count_known_domains do
    # Each follower is stored by its ActivityPub actor URI. The set of
    # remote domains we know about is the set of distinct hosts across
    # those URIs (plus local, minus nil parses).
    query =
      from f in Follow,
        where: not is_nil(f.follower_uri),
        select: f.follower_uri,
        distinct: true

    query
    |> Repo.all()
    |> Enum.map(&host_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp host_of(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: h} when is_binary(h) and h != "" -> h
      _ -> nil
    end
  end

  defp host_of(_), do: nil
end

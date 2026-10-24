# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.Fallback do
  @moduledoc """
  The safety net under notification: when a host will not take (or no longer
  understands) our notifications, push it everything it has not been told
  about, through the ordinary `Delivery.Worker` path, and mark the backlog
  handled. After this a host is exactly where it would have been had it
  never been pulled from.

  Idempotent: `delivery_receipts` makes a repeated push of the same
  `(activity, inbox)` a no-op.
  """

  import Ecto.Query

  alias SukhiDelivery.Delivery.Worker
  alias SukhiDelivery.Outbox.Recipients
  alias SukhiDelivery.Repo
  alias SukhiShared.{PeerCapabilities, PullStats}

  @spec push(String.t()) :: non_neg_integer()
  def push(host) do
    through =
      Repo.one(from(p in "pull_peers", where: p.host == ^host, select: p.notified_through)) || 0

    domain = SukhiDelivery.Config.domain!()

    rows =
      from(l in "pull_log",
        join: a in "accounts",
        on: a.id == l.account_id,
        where: l.id > ^through,
        order_by: l.id,
        select: %{id: l.id, activity_id: l.activity_id, body: l.body, username: a.username}
      )
      |> Repo.all()

    jobs =
      rows
      |> Enum.group_by(& &1.username)
      |> Enum.flat_map(fn {username, entries} ->
        actor_uri = "https://#{domain}/users/#{username}"

        inboxes =
          actor_uri
          |> Recipients.followers_inboxes()
          |> Enum.filter(&(PeerCapabilities.host_of(&1) == String.downcase(host)))
          |> Enum.uniq()

        for e <- entries, inbox <- inboxes do
          Worker.new(%{
            raw_json: e.body,
            actor_uri: actor_uri,
            activity_id: e.activity_id,
            inbox_url: inbox
          })
        end
      end)

    Oban.insert_all(SukhiDelivery.Oban, jobs)

    if rows != [] do
      through = rows |> Enum.map(& &1.id) |> Enum.max()

      Repo.query!(
        """
        INSERT INTO pull_peers (host, notified_through) VALUES ($1, $2)
        ON CONFLICT (host) DO UPDATE SET notified_through = GREATEST(pull_peers.notified_through, EXCLUDED.notified_through)
        """,
        [host, through]
      )
    end

    PullStats.bump("push_fallback", n: length(jobs), host: host)
    length(jobs)
  end
end

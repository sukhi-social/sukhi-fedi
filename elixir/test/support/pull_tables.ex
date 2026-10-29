# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullTables do
  @moduledoc """
  Test helpers for the Pull Federation tables: plain Ecto, so a test reads
  the same on Postgres and on Datalevin (no raw SQL).
  """

  import Ecto.Query

  alias SukhiFedi.Repo

  @doc "Set an actor's head to at least `seq`."
  def put_head(account_id, seq) do
    Repo.insert_all("pull_heads", [%{account_id: account_id, seq: seq}],
      on_conflict: :nothing,
      conflict_target: [:account_id]
    )

    from(h in "pull_heads", where: h.account_id == ^account_id and h.seq < ^seq)
    |> Repo.update_all(set: [seq: seq])

    :ok
  end

  def prune_through(account_id, seq),
    do:
      from(h in "pull_heads", where: h.account_id == ^account_id)
      |> Repo.update_all(set: [pruned_through: seq])

  def put_log(account_id, seq, body \\ %{"type" => "Create"}) do
    Repo.insert_all("pull_log", [
      %{account_id: account_id, seq: seq, activity_id: "act-#{account_id}-#{seq}", body: body}
    ])

    :ok
  end

  def delete_log_through(account_id, seq),
    do: Repo.delete_all(from(l in "pull_log", where: l.account_id == ^account_id and l.seq <= ^seq))

  def delete_log_at(account_id, seq),
    do: Repo.delete_all(from(l in "pull_log", where: l.account_id == ^account_id and l.seq == ^seq))

  def put_pending(host, actor_uri, head) do
    Repo.insert_all("pull_pending", [
      %{host: host, actor_uri: actor_uri, head: head, received_at: NaiveDateTime.utc_now()}
    ])

    :ok
  end

  def pending(host) do
    from(p in "pull_pending",
      where: p.host == ^host,
      order_by: p.actor_uri,
      select: [p.actor_uri, p.head]
    )
    |> Repo.all()
  end

  def put_cursor(actor_uri, host, seq) do
    Repo.insert_all("pull_cursors", [
      %{actor_uri: actor_uri, host: host, seq: seq, updated_at: NaiveDateTime.utc_now()}
    ])

    :ok
  end

  def cursor(actor_uri),
    do: Repo.all(from(c in "pull_cursors", where: c.actor_uri == ^actor_uri, select: [c.seq]))

  def put_host(host, failures),
    do:
      Repo.insert_all("pull_hosts", [
        %{host: host, next_pull_at: NaiveDateTime.utc_now(), failures: failures}
      ])

  def put_peer(host, failures, last_error) do
    Repo.insert_all("pull_peers", [
      %{host: host, failures: failures, last_error: last_error, notified_at: NaiveDateTime.utc_now()}
    ])
  end
end

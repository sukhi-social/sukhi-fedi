# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.BackfillTest do
  @moduledoc """
  `/admin/backfill` が読む進行状態のクエリ。取得そのもの（outbox を
  signed fetch で辿る）はネットワークなので、ここでは DB に残る
  `accounts.backfill_*` と一覧・集計だけを見る。

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query, only: [from: 2]

  alias SukhiFedi.Federation.OutboxBackfill
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Follow}

  test "list/counts は follow している remote だけを数える" do
    me = create_account!("bf_me")
    followed = create_remote_account!("bf_followed", "bf.example")
    pending_remote = create_remote_account!("bf_pending", "bf.example")
    _unfollowed = create_remote_account!("bf_unfollowed", "bf.example")

    accept_follow!(me, followed)
    pending_follow!(me, pending_remote)

    ids = OutboxBackfill.list() |> Enum.map(& &1.id)
    assert followed.id in ids
    refute pending_remote.id in ids

    counts = OutboxBackfill.counts()
    assert counts.untouched >= 1
  end

  test "mark_pending は未着手を pending にし、running は触らない" do
    me = create_account!("bf_mark_me")
    remote = create_remote_account!("bf_mark", "bf.example")
    accept_follow!(me, remote)

    :ok = OutboxBackfill.mark_pending(remote.actor_uri)
    assert reload(remote).backfill_state == "pending"

    # 走っている最中に enqueue されても pending へは戻さない。
    Repo.update_all(from(a in Account, where: a.id == ^remote.id),
      set: [backfill_state: "running"]
    )

    :ok = OutboxBackfill.mark_pending(remote.actor_uri)
    assert reload(remote).backfill_state == "running"
  end

  defp reload(account), do: Repo.get!(Account, account.id)

  defp accept_follow!(follower, followee) do
    %Follow{follower_uri: actor_uri(follower), followee_id: followee.id, state: "accepted"}
    |> Repo.insert!()
  end

  defp pending_follow!(follower, followee) do
    %Follow{follower_uri: actor_uri(follower), followee_id: followee.id, state: "pending"}
    |> Repo.insert!()
  end

  defp actor_uri(account), do: "https://#{SukhiFedi.Config.domain!()}/users/#{account.username}"

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp create_remote_account!(username, domain) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: domain,
      actor_uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/users/#{username}/inbox"
    }
    |> Repo.insert!()
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.DecoFederationTest do
  @moduledoc """
  natadeco の板(デコ)の Group actor — 実ルーターを通した HTTP の形。
  段階の最初(actor が引ける・webfinger で見つかる)だけを確かめる。
  Follow の受理・followers の中身はまだ先の段。

      podman compose -f docker-compose.test.yml up -d postgres nats
      MIX_ENV=test mix sukhi.migrate
      mix test --only integration test/integration/deco_federation_test.exs
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Conn
  import Plug.Test

  alias SukhiFedi.Addons.Deco
  alias SukhiFedi.LocalAccounts
  alias SukhiFedi.Web.Router

  @opts Router.init([])

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, "localhost:4000")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)

    n = System.unique_integer([:positive])
    {:ok, author} = LocalAccounts.create_admin("deco_fed_#{n}", "long-enough-pass")
    {:ok, deco} = Deco.create_deco(author, %{"slug" => "shiro#{n}", "name" => "しろい板"})
    %{deco: deco}
  end

  defp get_ap(path) do
    conn(:get, path)
    |> put_req_header("accept", "application/activity+json")
    |> Router.call(@opts)
  end

  test "GET /users/:slug-deco が Group actor JSON を返す", %{deco: deco} do
    conn = get_ap("/users/#{deco.slug}-deco")

    assert conn.status == 200
    assert conn |> Plug.Conn.get_resp_header("content-type") |> hd() =~ "application/activity+json"

    body = JSON.decode!(conn.resp_body)
    assert body["type"] == "Group"
    assert body["preferredUsername"] == "#{deco.slug}-deco"
    assert body["name"] == deco.name
    assert body["id"] == "https://localhost:4000/users/#{deco.slug}-deco"
    assert body["publicKey"]["publicKeyPem"] != ""
  end

  test "無い板の slug-deco は 404", do: assert(get_ap("/users/no-such-slug-deco").status == 404)

  describe "引かれたときも、配るときと同じことを名乗る" do
    # 同じ note が二つの道で外へ出る ── 配るとき(`Fedi.Builders`)と、
    # 引かれるとき(`Web.NoteController`)。返信してきた相手のサーバは
    # たいてい引きに来るので、片方だけ整えると「返信されたときにだけ
    # 題も板も消える」という見つけにくい形になる。2026-08-26 に一度
    # そうなった。組み立ては `SukhiFedi.AP.Titled` の一箇所にある。
    setup %{deco: deco} do
      {:ok, author} =
        LocalAccounts.create_admin("wire_#{System.unique_integer([:positive])}", "long-enough-pass")

      # 新規アカウントの投稿ペース制限に巻き込まれないよう、古参として
      # 作る ── ここの主題は「線の上でどう名乗るか」なので。
      author =
        author
        |> Ecto.Changeset.change(
          created_at: DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)
        )
        |> SukhiFedi.Repo.update!()

      {:ok, post} =
        Deco.post(author, deco.slug, %{"title" => "夜ごはんの話", "status" => "なにたべよう"})

      %{author: author, post: post}
    end

    defp fetched(author, post), do: get_ap("/users/#{author.username}/notes/#{post.id}") |> then(&JSON.decode!(&1.resp_body))

    test "題は `name` に載る", %{author: author, post: post} do
      assert fetched(author, post)["name"] == "夜ごはんの話"
    end

    test "どの板のものかを名乗る", %{author: author, post: post, deco: deco} do
      body = fetched(author, post)

      assert body["audience"] == "https://localhost:4000/users/#{deco.slug}-deco"
      # `to` に入れると Mastodon が板を silent mention として解決する。
      refute body["audience"] in List.wrap(body["to"])
      refute body["audience"] in List.wrap(body["cc"])
    end

    test "本文の頭に「題 — @書いた人」が付く", %{author: author, post: post} do
      body = fetched(author, post)

      assert String.starts_with?(body["content"], "<blockquote>")
      assert body["content"] =~ "夜ごはんの話"
      assert body["content"] =~ "@#{author.username}@localhost:4000"
      assert body["content"] =~ "なにたべよう"
    end

    test "書いた人は本物の Mention", %{author: author, post: post} do
      tags = fetched(author, post)["tag"] || []

      assert Enum.any?(tags, fn t ->
               t["type"] == "Mention" and t["name"] == "@#{author.username}@localhost:4000"
             end)
    end

    test "既定は Note ── 選ばなければ本文が外でも読める", %{author: author, post: post} do
      body = fetched(author, post)
      assert body["type"] == "Note"
      refute Map.has_key?(body, "summary")
    end

    test "長い文章として出したものは Article + 書き出し", %{author: author, deco: deco} do
      {:ok, long} =
        Deco.post(author, deco.slug, %{
          "title" => "ながい話",
          "status" => "ずっとつづく はなし",
          "as_article" => true
        })

      body = fetched(author, long)
      assert body["type"] == "Article"
      assert body["summary"] =~ "ずっとつづく"
    end

    test "題の無い投稿は、素の Note のまま", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, talk} =
        Deco.create_deco(author, %{"slug" => "talk#{n}", "name" => "はなす板", "kind" => "talk"})

      {:ok, post} = Deco.post(author, talk.slug, %{"status" => "ひとこと"})
      body = fetched(author, post)

      assert body["type"] == "Note"
      refute Map.has_key?(body, "name")
      refute String.starts_with?(body["content"], "<blockquote>")
    end
  end

  test "webfinger が acct:slug-deco@domain を解決する", %{deco: deco} do
    conn = get_ap("/.well-known/webfinger?resource=acct:#{deco.slug}-deco@localhost:4000")

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert body["subject"] == "acct:#{deco.slug}-deco@localhost:4000"

    self_link = Enum.find(body["links"], &(&1["rel"] == "self"))
    assert self_link["href"] == "https://localhost:4000/users/#{deco.slug}-deco"

    # `type: "text/html"` と言う以上、行き先は人が読む板の頁 ── actor の
    # `id` ではない(そこは AP JSON しか返さないことがある)。
    page = Enum.find(body["links"], &(&1["rel"] == "http://webfinger.net/rel/profile-page"))
    assert page["type"] == "text/html"
    assert page["href"] == "https://localhost:4000/d/#{deco.slug}"
  end

  describe "表札を出さない板" do
    setup do
      n = System.unique_integer([:positive])

      {:ok, author} = LocalAccounts.create_admin("deco_quiet_#{n}", "long-enough-pass")

      {:ok, quiet} =
        Deco.create_deco(author, %{
          "slug" => "quiet#{n}",
          "name" => "しずかな板",
          "has_actor" => false
        })

      %{quiet: quiet}
    end

    test "actor は 404 ── 外から見れば、そこには何も無い", %{quiet: quiet} do
      assert get_ap("/users/#{quiet.slug}-deco").status == 404
    end

    test "webfinger も見つけない", %{quiet: quiet} do
      conn = get_ap("/.well-known/webfinger?resource=acct:#{quiet.slug}-deco@localhost:4000")
      assert conn.status == 404
    end
  end

  describe "板を追う（外から）" do
    alias SukhiFedi.Addons.Deco, as: D

    defp uri_of(deco), do: SukhiFedi.AP.GroupJson.actor_uri(deco.slug)

    test "Follow を受けると、その相手が残る", %{deco: deco} do
      assert :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")

      assert {:ok, ["https://remote.test/users/a"]} = D.follower_uris(deco.slug)
      assert D.follower_inboxes(deco.id) == ["https://remote.test/inbox"]
    end

    test "二度来ても一度きり", %{deco: deco} do
      :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")
      :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")

      assert {:ok, [_one]} = D.follower_uris(deco.slug)
    end

    test "やめれば落ちる", %{deco: deco} do
      :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")
      :ok = D.drop_follow(uri_of(deco), "https://remote.test/users/a")

      assert {:ok, []} = D.follower_uris(deco.slug)
    end

    test "無い板への Follow は :not_found", %{} do
      assert {:error, :not_found} =
               D.record_follow("https://localhost:4000/users/nope-deco", "https://remote.test/users/a", nil)
    end

    test "followers コレクションが引ける", %{deco: deco} do
      :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")

      conn = get_ap("/users/#{deco.slug}-deco/followers")
      assert conn.status == 200

      body = JSON.decode!(conn.resp_body)
      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 1
      assert body["orderedItems"] == ["https://remote.test/users/a"]
    end

    test "新しい話が立つと、追っている相手へ配る積み荷ができる", %{deco: deco} do
      {:ok, author} =
        LocalAccounts.create_admin("ann_#{System.unique_integer([:positive])}", "long-enough-pass")

      author =
        author
        |> Ecto.Changeset.change(
          created_at: DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)
        )
        |> SukhiFedi.Repo.update!()

      :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")

      {:ok, post} = D.post(author, deco.slug, %{"title" => "題", "status" => "本文"})

      ev = last_announce()
      assert ev, "板の Announce が outbox に積まれていない"
      assert ev.payload["deco_actor"] == uri_of(deco)
      assert ev.payload["inboxes"] == ["https://remote.test/inbox"]
      assert ev.payload["object"] =~ "/notes/#{post.id}"
    end

    test "返信は配らない ── 追った人の面に一言ずつは流さない", %{deco: deco} do
      {:ok, author} =
        LocalAccounts.create_admin("ann2_#{System.unique_integer([:positive])}", "long-enough-pass")

      author =
        author
        |> Ecto.Changeset.change(
          created_at: DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)
        )
        |> SukhiFedi.Repo.update!()

      :ok = D.record_follow(uri_of(deco), "https://remote.test/users/a", "https://remote.test/inbox")
      {:ok, post} = D.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      before = last_announce()

      {:ok, _} = D.reply(author, post.id, %{"status" => "つづき"})

      assert last_announce().id == before.id, "返信でも Announce が積まれている"
    end

    test "追っている人が居なければ、積まない", %{deco: deco} do
      {:ok, author} =
        LocalAccounts.create_admin("ann3_#{System.unique_integer([:positive])}", "long-enough-pass")

      author =
        author
        |> Ecto.Changeset.change(
          created_at: DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)
        )
        |> SukhiFedi.Repo.update!()

      {:ok, _} = D.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      refute last_announce()
    end

    defp last_announce do
      import Ecto.Query

      SukhiFedi.Repo.one(
        from(e in SukhiFedi.Schema.OutboxEvent,
          where: e.subject == "sns.outbox.announce.created" and e.aggregate_type == "deco",
          order_by: [desc: e.id],
          limit: 1
        )
      )
    end

    test "無い板の followers は 404" do
      assert get_ap("/users/nope-deco/followers").status == 404
    end
  end

  test "板の slug 自体(suffix 無し)は、板の actor としては解決しない", %{deco: deco} do
    # `hinata@domain` は個人アカウントの名前空間 ── デコの actor はいつも
    # `hinata-deco@domain` の方。無いアカウントとして 404 になる。
    conn = get_ap("/users/#{deco.slug}")
    assert conn.status == 404
  end
end

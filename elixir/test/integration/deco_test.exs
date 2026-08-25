# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.DecoTest do
  @moduledoc """
  natadeco の板（デコ）。器と、呼び名。

      podman compose -f docker-compose.test.yml up -d postgres nats nats-bootstrap
      MIX_ENV=test mix sukhi.migrate
      mix test --only integration test/integration/deco_test.exs
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query

  @moduletag :integration

  alias SukhiFedi.Addons.Deco
  alias SukhiFedi.LocalAccounts
  alias SukhiFedi.Schema.Account

  setup do
    n = System.unique_integer([:positive])
    {:ok, author} = LocalAccounts.create_admin("deco_#{n}", "long-enough-pass")
    # 新規アカウントの投稿ペース制限(下の describe で別に確かめる)に、
    # この author を使う他のテストが巻き込まれないように、古参として
    # 作る ── ここでのテストの主題は「板の仕組み」であって「新規制限」
    # ではないので。
    author = age_account(author)
    {:ok, deco} = Deco.create_deco(author, %{"slug" => "shiro#{n}", "name" => "しろい板"})
    %{author: author, deco: deco}
  end

  defp age_account(%Account{} = account) do
    old = DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)

    account
    |> Ecto.Changeset.change(created_at: old)
    |> SukhiFedi.Repo.update!()
  end

  describe "板" do
    test "名前で作って、slug で引ける", %{deco: deco} do
      assert {:ok, found} = Deco.get_deco(deco.slug)
      assert found.name == "しろい板"
      assert found.post_count == 0
    end

    test "同じ slug は二枚作れない", %{author: author, deco: deco} do
      assert {:error, {:validation, %{slug: _}}} =
               Deco.create_deco(author, %{"slug" => deco.slug, "name" => "べつの板"})
    end

    test "slug の形が変なら断る", %{author: author} do
      assert {:error, {:validation, %{slug: _}}} =
               Deco.create_deco(author, %{"slug" => "ダメ な スラグ", "name" => "板"})
    end

    test "紛らわしい名前は断る", %{author: author} do
      assert {:error, {:validation, %{slug: _}}} =
               Deco.create_deco(author, %{"slug" => "admin", "name" => "板"})
    end

    test "一覧は名前順 ── 数の多い順ではなく", %{author: author} do
      n = System.unique_integer([:positive])
      {:ok, _} = Deco.create_deco(author, %{"slug" => "zz#{n}", "name" => "あいうえお#{n}"})
      {:ok, _} = Deco.create_deco(author, %{"slug" => "aa#{n}", "name" => "んんんん#{n}"})

      names = Deco.list_decos() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end

    test "畳むと、中の投稿も本当に消える", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "きえる", "status" => "…"})

      assert :ok = Deco.delete_deco(deco.slug)

      assert {:error, :not_found} = Deco.get_deco(deco.slug)
      refute SukhiFedi.Repo.get(SukhiFedi.Schema.Note, post.id)
    end

    test "無い板を畳もうとしても :not_found" do
      assert {:error, :not_found} = Deco.delete_deco("no-such-deco")
    end
  end

  describe "多言語(板・投稿)" do
    test "板の名前・説明に、他言語を上乗せできる", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, deco} =
        Deco.create_deco(author, %{
          "slug" => "multi#{n}",
          "name" => "ひなたぼっこ",
          "description" => "あたたかい板",
          "name_i18n" => %{"ko" => "해바라기"},
          "description_i18n" => %{"ko" => "따뜻한 게시판"}
        })

      assert deco.name_i18n == %{"ko" => "해바라기"}
      assert deco.description_i18n == %{"ko" => "따뜻한 게시판"}

      assert {:ok, found} = Deco.get_deco(deco.slug)
      assert found.name_i18n == %{"ko" => "해바라기"}
    end

    test "空欄のタブは、その言語として保存しない", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, deco} =
        Deco.create_deco(author, %{
          "slug" => "empty#{n}",
          "name" => "테스트",
          "name_i18n" => %{"ko" => "  "}
        })

      # トリムすると空欄 → その言語では書かなかった扱いにする。
      assert deco.name_i18n == %{}
    end

    test "主言語が韓国語の板にも、日本語を添えられる(ja を決め打ちしない)", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, deco} =
        Deco.create_deco(author, %{
          "slug" => "koprimary#{n}",
          "name" => "테스트 게시판",
          "name_i18n" => %{"ja" => "テスト板"}
        })

      # name(主)が韓国語で、日本語のほうが上乗せ ── 逆もできる、という
      # ことは「どちらかを主言語に決め打ちしていない」証拠。
      assert deco.name == "테스트 게시판"
      assert deco.name_i18n == %{"ja" => "テスト板"}
    end

    test "投稿の題・本文にも、他言語を上乗せできる", %{author: author, deco: deco} do
      {:ok, post} =
        Deco.post(author, deco.slug, %{
          "title" => "はじめまして",
          "status" => "こんにちは",
          "title_i18n" => %{"ko" => "처음 뵙겠습니다"},
          "content_i18n" => %{"ko" => "**안녕하세요**"}
        })

      assert post.title_i18n == %{"ko" => "처음 뵙겠습니다"}
      # content_i18n は Markdown → HTML 化されて返る(notes の content_html と同じ扱い)。
      assert post.content_html_i18n["ko"] =~ "<strong>안녕하세요</strong>"

      assert {:ok, again} = Deco.get_post(post.id)
      assert again.title_i18n == %{"ko" => "처음 뵙겠습니다"}
    end

    test "上乗せ無しなら、i18n は空地図のまま", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "ふつう", "status" => "ふつう"})
      assert post.title_i18n == %{}
      assert post.content_html_i18n == %{}
    end
  end

  describe "Group actor(連合)" do
    test "作ると鍵一式が付く", %{deco: deco} do
      assert {:ok, %SukhiFedi.Schema.Deco{} = record} = Deco.get_deco_record(deco.slug)
      assert is_binary(record.public_key_pem) and record.public_key_pem != ""
      assert is_map(record.public_key_jwk)
      assert is_map(record.private_key_jwk)
      assert is_map(record.ed25519_private_key_jwk)
      assert is_binary(record.ed25519_public_multibase) and record.ed25519_public_multibase != ""
    end

    test "get_deco_record/1 は無い板を :not_found で返す" do
      assert {:error, :not_found} = Deco.get_deco_record("no-such-deco")
    end
  end

  describe "書く・読む" do
    test "題つきで一件書ける", %{author: author, deco: deco} do
      assert {:ok, post} =
               Deco.post(author, deco.slug, %{"title" => "はじめまして", "status" => "こんにちは"})

      assert post.title == "はじめまして"
      assert post.content_html =~ "こんにちは"
      assert post.reply_count == 0

      assert {:ok, [listed]} = Deco.list_posts(deco.slug)
      assert listed.id == post.id
    end

    test "本文のカスタム絵文字は emojis に乗って返る", %{author: author, deco: deco} do
      {:ok, _} = SukhiFedi.CustomEmojis.register(%{shortcode: "blobfox_#{deco.id}", image_url: "https://example.test/blobfox.png"})

      {:ok, post} =
        Deco.post(author, deco.slug, %{
          "title" => "絵文字",
          "status" => "やあ :blobfox_#{deco.id}:"
        })

      assert [%{"shortcode" => "blobfox_" <> _, "url" => "https://example.test/blobfox.png"}] = post.emojis
    end

    test "題が無いと断る ── 一覧に並ぶのは題だけなので", %{author: author, deco: deco} do
      assert {:error, {:validation, %{title: _}}} =
               Deco.post(author, deco.slug, %{"status" => "ぽつり"})

      assert {:error, {:validation, %{title: _}}} =
               Deco.post(author, deco.slug, %{"title" => "   ", "status" => "ぽつり"})
    end

    test "レスには題を要らない", %{author: author, deco: deco} do
      {:ok, parent} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      assert {:ok, _} = Deco.reply(author, parent.id, %{"status" => "うんうん"})
    end

    test "レスは親にぶら下がり、一覧には出てこない", %{author: author, deco: deco} do
      {:ok, parent} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      {:ok, child} = Deco.reply(author, parent.id, %{"status" => "うんうん"})

      # 板の一覧に出るのは親だけ（レスで板が埋まらないように）
      assert {:ok, [listed]} = Deco.list_posts(deco.slug)
      assert listed.id == parent.id
      assert listed.reply_count == 1

      # レスは、親を開いたときに、古い順に並ぶ
      assert {:ok, opened} = Deco.get_post(parent.id)
      assert Enum.map(opened.replies, & &1.id) == [child.id]

      # レスも同じ板のもの
      assert child.deco_id == parent.deco_id
    end

    test "動きのあった投稿が上に来る ── 古くても、レスが付けば", %{author: author, deco: deco} do
      {:ok, older} = Deco.post(author, deco.slug, %{"title" => "ふるい話", "status" => "…"})
      {:ok, newer} = Deco.post(author, deco.slug, %{"title" => "あたらしい話", "status" => "…"})

      # このままなら、あたらしい話が先(投稿順)。
      assert {:ok, [first, _second]} = Deco.list_posts(deco.slug)
      assert first.id == newer.id

      # ふるい話にレスが付くと、順位が入れ替わる。
      # (created_at は秒精度なので、同じ秒だと同点になってしまう ──
      # 秒境界をまたいでから確かめる)
      Process.sleep(1100)
      {:ok, _} = Deco.reply(author, older.id, %{"status" => "うんうん"})

      assert {:ok, [first, second]} = Deco.list_posts(deco.slug)
      assert first.id == older.id
      assert second.id == newer.id
      assert DateTime.compare(first.last_activity_at, first.created_at) == :gt
    end

    test "「もっと読む」は、動きの順のまま続きを取れる", %{author: author, deco: deco} do
      {:ok, a} = Deco.post(author, deco.slug, %{"title" => "いち", "status" => "…"})
      {:ok, b} = Deco.post(author, deco.slug, %{"title" => "に", "status" => "…"})
      {:ok, c} = Deco.post(author, deco.slug, %{"title" => "さん", "status" => "…"})

      assert {:ok, [first]} = Deco.list_posts(deco.slug, limit: 1)
      assert first.id == c.id

      assert {:ok, [second]} =
               Deco.list_posts(deco.slug,
                 limit: 1,
                 before_activity_at: first.last_activity_at,
                 before_id: first.id
               )

      assert second.id == b.id

      assert {:ok, [third]} =
               Deco.list_posts(deco.slug,
                 limit: 1,
                 before_activity_at: second.last_activity_at,
                 before_id: second.id
               )

      assert third.id == a.id
    end

    test "無い板には書けない", %{author: author} do
      assert {:error, :not_found} = Deco.post(author, "nowhere", %{"status" => "だれか"})
    end

    test "板の投稿でないものには、ぶら下げられない", %{author: author} do
      {:ok, plain} = SukhiFedi.Notes.create_status(author.id, %{"status" => "ふつうの投稿"})
      assert {:error, :not_found} = Deco.reply(author, plain.id, %{"status" => "レス"})
    end
  end

  describe "公開範囲(全域/ローカル)" do
    test "何も指定しなければ全域(local_only は false)", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "ふつう", "status" => "ふつう"})
      assert post.local_only == false

      dn = SukhiFedi.Repo.get_by(SukhiFedi.Schema.DecoNote, note_id: post.id)
      assert dn.local_only == false
    end

    test "visibility: local を指定すると local_only になる", %{author: author, deco: deco} do
      {:ok, post} =
        Deco.post(author, deco.slug, %{"title" => "うちだけ", "status" => "うちだけ", "visibility" => "local"})

      assert post.local_only == true

      # notes.visibility 自体は "public" のまま ── 見える範囲は変えず、
      # 連合に出すかどうかだけを変える。
      note = SukhiFedi.Repo.get(SukhiFedi.Schema.Note, post.id)
      assert note.visibility == "public"
    end

    test "outbox イベントにも local_only が乗る ── 配達側が見る場所", %{author: author, deco: deco} do
      {:ok, post} =
        Deco.post(author, deco.slug, %{"title" => "だまって", "status" => "だまって", "visibility" => "local"})

      ev =
        SukhiFedi.Repo.one!(
          from(e in SukhiFedi.Schema.OutboxEvent,
            where: e.subject == "sns.outbox.note.created" and e.aggregate_id == ^to_string(post.id)
          )
        )

      assert ev.payload["local_only"] == true
    end

    test "レスにも公開範囲を選べる", %{author: author, deco: deco} do
      {:ok, parent} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      {:ok, reply} = Deco.reply(author, parent.id, %{"status" => "うちだけの返事", "visibility" => "local"})
      assert reply.local_only == true
    end
  end

  describe "書いた人（note.com 式 ── 隠さない）" do
    test "投稿には、書いた人の名前とハンドルがついてくる", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "はじめまして", "status" => "こんにちは"})

      assert post.author.username == author.username
      assert post.author.acct == author.username
      assert post.author.display_name == author.display_name
    end

    test "同じ人の投稿は、同じ名前で並ぶ", %{author: author, deco: deco} do
      {:ok, a} = Deco.post(author, deco.slug, %{"title" => "ひとつめ", "status" => "ひとつめ"})
      {:ok, b} = Deco.post(author, deco.slug, %{"title" => "ふたつめ", "status" => "ふたつめ"})
      assert a.author.acct == b.author.acct
    end

    test "板がちがっても、同じ人は同じ名前", %{author: author, deco: deco} do
      n = System.unique_integer([:positive])
      {:ok, other} = Deco.create_deco(author, %{"slug" => "other#{n}", "name" => "べつの板"})

      {:ok, here} = Deco.post(author, deco.slug, %{"title" => "こっち", "status" => "こっち"})
      {:ok, there} = Deco.post(author, other.slug, %{"title" => "あっち", "status" => "あっち"})

      assert here.author.acct == there.author.acct
    end

    test "読み返しても、同じ人のまま", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "きょうの分", "status" => "きょうの分"})
      assert {:ok, again} = Deco.get_post(post.id)
      assert again.author == post.author
    end

    test "レスにも、書いた人がついてくる", %{author: author, deco: deco} do
      {:ok, parent} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "おはなし"})
      {:ok, _} = Deco.reply(author, parent.id, %{"status" => "うんうん"})

      assert {:ok, opened} = Deco.get_post(parent.id)
      assert [%{author: %{acct: acct}}] = opened.replies
      assert acct == author.username
    end
  end

  describe "直す" do
    test "直す前の下書きに、元の生の文が(HTML化もエスケープもされず)返る", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "山括弧", "status" => "1 < 2 & 3 > 0"})

      assert post.content == "1 < 2 & 3 > 0"
      assert post.content_html =~ "1 &lt; 2 &amp; 3 &gt; 0"
    end

    test "自分の投稿を直せる ── 本文も題も", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "もとの題", "status" => "もとの本文"})

      assert {:ok, updated} =
               Deco.update_post(author, post.id, %{"title" => "なおした題", "status" => "なおした本文"})

      assert updated.title == "なおした題"
      assert updated.content_html =~ "なおした本文"

      assert {:ok, again} = Deco.get_post(post.id)
      assert again.title == "なおした題"
      assert again.content_html =~ "なおした本文"
    end

    test "レスも直せる（題は要らない）", %{author: author, deco: deco} do
      {:ok, parent} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      {:ok, reply} = Deco.reply(author, parent.id, %{"status" => "うんうん"})

      assert {:ok, updated} = Deco.update_post(author, reply.id, %{"status" => "やっぱりそうだね"})
      assert updated.content_html =~ "やっぱりそうだね"
    end

    test "もう一つの言語ぶんも直せる", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "はじめまして", "status" => "こんにちは"})

      assert {:ok, updated} =
               Deco.update_post(author, post.id, %{
                 "title_i18n" => %{"ko" => "다시 왔어요"},
                 "content_i18n" => %{"ko" => "**다시 씀**"}
               })

      assert updated.title_i18n == %{"ko" => "다시 왔어요"}
      assert updated.content_html_i18n["ko"] =~ "<strong>다시 씀</strong>"
      # 直した欄だけ変わって、主言語はそのまま。
      assert updated.title == "はじめまして"
      assert updated.content_html =~ "こんにちは"
    end

    test "他人の投稿は直せない ── :forbidden", %{author: author, deco: deco} do
      n = System.unique_integer([:positive])
      {:ok, someone_else} = LocalAccounts.create_admin("other_#{n}", "long-enough-pass")

      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "わたしの", "status" => "わたしの本文"})

      assert {:error, :forbidden} =
               Deco.update_post(someone_else, post.id, %{"status" => "のっとった"})

      # 中身は変わっていない。
      assert {:ok, unchanged} = Deco.get_post(post.id)
      assert unchanged.content_html =~ "わたしの本文"
    end

    test "無い投稿は :not_found", %{author: author} do
      assert {:error, :not_found} = Deco.update_post(author, 999_999_999, %{"status" => "…"})
    end

    test "題を空にはできない ── 一覧に並ぶのは題だけなので", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題あり", "status" => "本文"})

      assert {:error, {:validation, %{title: _}}} =
               Deco.update_post(author, post.id, %{"title" => "   "})

      assert {:ok, unchanged} = Deco.get_post(post.id)
      assert unchanged.title == "題あり"
    end

    test "全域の投稿を直すと Update(Note) の配達が積まれる", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "ひろく", "status" => "もと"})
      {:ok, _} = Deco.update_post(author, post.id, %{"status" => "なおした"})

      assert SukhiFedi.Repo.exists?(
               from(e in SukhiFedi.Schema.OutboxEvent,
                 where: e.subject == "sns.outbox.note.updated" and e.aggregate_id == ^to_string(post.id)
               )
             )
    end

    test "ローカル限定の投稿を直しても、配達は積まれない", %{author: author, deco: deco} do
      {:ok, post} =
        Deco.post(author, deco.slug, %{"title" => "うちだけ", "status" => "もと", "visibility" => "local"})

      {:ok, _} = Deco.update_post(author, post.id, %{"status" => "なおした"})

      refute SukhiFedi.Repo.exists?(
               from(e in SukhiFedi.Schema.OutboxEvent,
                 where: e.subject == "sns.outbox.note.updated" and e.aggregate_id == ^to_string(post.id)
               )
             )
    end
  end

  describe "消す" do
    test "自分の投稿を消せる ── deco_notes の行も一緒に消える", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "きえる", "status" => "…"})

      assert :ok = Deco.delete_post(author, post.id)

      assert {:error, :not_found} = Deco.get_post(post.id)
      refute SukhiFedi.Repo.get(SukhiFedi.Schema.Note, post.id)
      refute SukhiFedi.Repo.get_by(SukhiFedi.Schema.DecoNote, note_id: post.id)
    end

    test "自分のレスも消せる", %{author: author, deco: deco} do
      {:ok, parent} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      {:ok, reply} = Deco.reply(author, parent.id, %{"status" => "うんうん"})

      assert :ok = Deco.delete_post(author, reply.id)

      assert {:ok, opened} = Deco.get_post(parent.id)
      assert opened.replies == []
    end

    test "他人の投稿は消せない ── :forbidden", %{author: author, deco: deco} do
      n = System.unique_integer([:positive])
      {:ok, someone_else} = LocalAccounts.create_admin("deleter_#{n}", "long-enough-pass")

      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "わたしの", "status" => "わたしの本文"})

      assert {:error, :forbidden} = Deco.delete_post(someone_else, post.id)
      assert {:ok, _} = Deco.get_post(post.id)
    end

    test "無い投稿は :not_found", %{author: author} do
      assert {:error, :not_found} = Deco.delete_post(author, 999_999_999)
    end
  end

  describe "レスの通知" do
    test "レスが付くと、返信先を書いた人に mention 通知が立つ", %{deco: deco} do
      n = System.unique_integer([:positive])
      {:ok, poster} = LocalAccounts.create_admin("poster_#{n}", "long-enough-pass")
      {:ok, replier} = LocalAccounts.create_admin("replier_#{n}", "long-enough-pass")

      {:ok, post} = Deco.post(poster, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      {:ok, reply} = Deco.reply(replier, post.id, %{"status" => "うんうん"})

      [notif] = SukhiFedi.Notifications.list(poster.id, [])
      assert notif.type == "mention"
      assert notif.from_account_id == replier.id
      assert notif.note_id == reply.id
    end

    test "自分のレスに自分で返信しても、通知は立たない", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "ひとりごと", "status" => "本文"})
      {:ok, _reply} = Deco.reply(author, post.id, %{"status" => "うんうん"})

      assert SukhiFedi.Notifications.list(author.id, []) == []
    end

    test "レスのレスは、直接の返信先の人に通知が立つ(根の投稿の人ではなく)", %{deco: deco} do
      n = System.unique_integer([:positive])
      {:ok, poster} = LocalAccounts.create_admin("root_#{n}", "long-enough-pass")
      {:ok, first_replier} = LocalAccounts.create_admin("first_#{n}", "long-enough-pass")
      {:ok, second_replier} = LocalAccounts.create_admin("second_#{n}", "long-enough-pass")

      {:ok, post} = Deco.post(poster, deco.slug, %{"title" => "おはなし", "status" => "本文"})
      {:ok, first} = Deco.reply(first_replier, post.id, %{"status" => "ひとつめ"})
      {:ok, _second} = Deco.reply(second_replier, first.id, %{"status" => "ふたつめ"})

      # first_replier 宛(second の返信)は一件。poster 宛は最初の返信の
      # ぶんが一件のまま(second の返信では増えない ── 根の投稿の人では
      # なく、直接の返信先である first_replier に通知が行ったので)。
      assert [_] = SukhiFedi.Notifications.list(first_replier.id, [])
      assert [%{from_account_id: from_id}] = SukhiFedi.Notifications.list(poster.id, [])
      assert from_id == first_replier.id
    end
  end

  describe "できたばかりのアカウントの、投稿ペース" do
    test "束にしては書けない ── 古参なら制限されない", %{author: author, deco: deco} do
      n = System.unique_integer([:positive])
      {:ok, fresh} = LocalAccounts.create_admin("fresh_#{n}", "long-enough-pass")

      assert {:ok, first} = Deco.post(fresh, deco.slug, %{"title" => "いっかいめ", "status" => "…"})

      assert {:error, :rate_limited} =
               Deco.post(fresh, deco.slug, %{"title" => "にかいめ", "status" => "…"})

      # レスにも同じ制限が掛かる(write/3 を通るのは同じなので)。
      assert {:error, :rate_limited} = Deco.reply(fresh, first.id, %{"status" => "うんうん"})

      # 主語は「書く人」。古参(setup の author)は、この間も普通に書ける。
      assert {:ok, _} = Deco.post(author, deco.slug, %{"title" => "だいじょうぶ", "status" => "…"})
    end
  end

  describe "反応" do
    # 返事を書くほど重くない「見たよ」。押せるだけでなく、読み返したときに
    # 戻ってきて初めて意味がある ── deco の view は自分では数えないので、
    # `with_reactions/2` が乗せているかを、ここで確かめる。
    test "押した反応が、読み返したときに返る", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})

      assert {:ok, _} = SukhiFedi.Notes.react(author, post.id, "✨")

      assert {:ok, read} = Deco.get_post(post.id, author.id)
      assert [%{name: "✨", count: 1, me: true}] = read.reactions
    end

    test "読む人が居なくても数は返る ── `me` が立たないだけ", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      {:ok, _} = SukhiFedi.Notes.react(author, post.id, "✨")

      assert {:ok, [listed]} = Deco.list_posts(deco.slug)
      assert [%{name: "✨", count: 1, me: false}] = listed.reactions
    end

    test "返信にも乗る", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      {:ok, r} = Deco.reply(author, post.id, %{"status" => "つづき"})
      {:ok, _} = SukhiFedi.Notes.react(author, r.id, "🌱")

      assert {:ok, read} = Deco.get_post(post.id, author.id)
      assert read.reactions == []
      assert [%{reactions: [%{name: "🌱", me: true}]}] = read.replies
    end

    test "誰も押していなければ空の列 ── 鍵の有無で形が変わらない", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})

      assert {:ok, read} = Deco.get_post(post.id)
      assert read.reactions == []
      assert {:ok, [listed]} = Deco.list_posts(deco.slug)
      assert listed.reactions == []
    end
  end

  describe "外へ出すかどうかの既定" do
    # 板ごとの性質。静かに話す板と、外へ届けたい板が、同じサーバに
    # 並んでいていい ── ただし既定であって、錠ではない。
    test "既定は外に出る ── いままでの板の振る舞い", %{author: author, deco: deco} do
      assert deco.local_only == false

      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      assert post.local_only == false
    end

    test "ローカル既定の板では、選ばなくてもローカルで書ける", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, quiet} =
        Deco.create_deco(author, %{"slug" => "quiet#{n}", "name" => "しずかな板", "local_only" => true})

      assert quiet.local_only == true

      {:ok, post} = Deco.post(author, quiet.slug, %{"title" => "題", "status" => "本文"})
      assert post.local_only == true
    end

    test "書く人が選べば、そちらが通る ── 板の既定を上書きできる", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, quiet} =
        Deco.create_deco(author, %{"slug" => "quiet#{n}", "name" => "しずかな板", "local_only" => true})

      {:ok, out} =
        Deco.post(author, quiet.slug, %{"title" => "題", "status" => "本文", "visibility" => "public"})

      assert out.local_only == false

      {:ok, open_deco} =
        Deco.create_deco(author, %{"slug" => "open#{n}", "name" => "ひらいた板"})

      {:ok, kept} =
        Deco.post(author, open_deco.slug, %{"title" => "題", "status" => "本文", "visibility" => "local"})

      assert kept.local_only == true
    end

    test "返信の既定は、板ではなく親に従う", %{author: author, deco: deco} do
      n = System.unique_integer([:positive])

      {:ok, quiet} =
        Deco.create_deco(author, %{"slug" => "quiet#{n}", "name" => "しずかな板", "local_only" => true})

      {:ok, post} = Deco.post(author, quiet.slug, %{"title" => "題", "status" => "本文"})
      {:ok, r} = Deco.reply(author, post.id, %{"status" => "つづき"})
      assert r.local_only == true

      # 外に出る板でも、ローカルに置かれた一件への返事は、黙って外へ
      # 出ない ── 部屋の中の話が、返事から漏れていかないように。
      {:ok, kept} =
        Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文", "visibility" => "local"})

      {:ok, r2} = Deco.reply(author, kept.id, %{"status" => "つづき"})
      assert r2.local_only == true
    end

    test "親がローカルでも、書く人が選べば外へ出せる", %{author: author, deco: deco} do
      {:ok, kept} =
        Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文", "visibility" => "local"})

      {:ok, out} = Deco.reply(author, kept.id, %{"status" => "つづき", "visibility" => "public"})
      assert out.local_only == false
    end
  end
  describe "表札" do
    # 板そのものが外から見つけられるかは、書いたものが外に出るかとは別。
    # 表札を出さない板でも、書いた人が選べばその一件は連合する ──
    # 出ていくのは板ではなく、その人の投稿だから。
    test "既定では表札が立つ ── いままでの板の振る舞い", %{deco: deco} do
      assert deco.has_actor == true
      assert {:ok, record} = Deco.get_actor_record(deco.slug)
      assert record.public_key_pem =~ "BEGIN PUBLIC KEY"
    end

    test "表札を出さない板は鍵を持たない", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, quiet} =
        Deco.create_deco(author, %{
          "slug" => "quiet#{n}",
          "name" => "しずかな板",
          "has_actor" => false
        })

      assert quiet.has_actor == false

      assert {:ok, record} = Deco.get_deco_record(quiet.slug)
      assert is_nil(record.public_key_pem)
      assert is_nil(record.private_key_jwk)

      # 連合の側から見れば、そこには何も無い（存在も漏らさない）。
      assert {:error, :not_found} = Deco.get_actor_record(quiet.slug)
    end

    test "表札が無くても、選べばその一件は外に出る", %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, quiet} =
        Deco.create_deco(author, %{
          "slug" => "quiet#{n}",
          "name" => "しずかな板",
          "has_actor" => false,
          "local_only" => true
        })

      {:ok, kept} = Deco.post(author, quiet.slug, %{"title" => "題", "status" => "本文"})
      assert kept.local_only == true

      {:ok, out} =
        Deco.post(author, quiet.slug, %{"title" => "題", "status" => "本文", "visibility" => "public"})

      assert out.local_only == false
    end
  end

  describe "隠れた板は作れない" do
    # natadeco に完全プライベートな板は無い。`local_only` も `has_actor`
    # も決めているのは「どこまで届くか」で、「誰が読めるか」ではない。
    #
    # ここが落ちたら、読む道のどこかに viewer の絞りが入っている。
    # それは掲示板ではない別のものなので、直すのはこのテストではなく
    # そちら側。あたたかいものは、隠さなくていい。
    setup %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, hidden} =
        Deco.create_deco(author, %{
          "slug" => "inside#{n}",
          "name" => "うちの中の板",
          "has_actor" => false,
          "local_only" => true
        })

      {:ok, post} = Deco.post(author, hidden.slug, %{"title" => "題", "status" => "本文"})
      {:ok, reply} = Deco.reply(author, post.id, %{"status" => "つづき"})

      %{hidden: hidden, post: post, reply: reply}
    end

    test "うちの中の板も、一覧に並ぶ", %{hidden: hidden} do
      slugs = Deco.list_decos() |> Enum.map(& &1.slug)
      assert hidden.slug in slugs
    end

    test "板そのものは、読む人が居なくても引ける", %{hidden: hidden} do
      assert {:ok, view} = Deco.get_deco(hidden.slug)
      assert view.local_only == true
      assert view.has_actor == false
    end

    test "ローカルの投稿も、読む人が居なくても読める", %{hidden: hidden, post: post} do
      assert {:ok, [listed]} = Deco.list_posts(hidden.slug)
      assert listed.id == post.id
      assert listed.local_only == true

      assert {:ok, read} = Deco.get_post(post.id)
      assert read.content_html =~ "本文"
      assert [%{content_html: html}] = read.replies
      assert html =~ "つづき"
    end

    test "読む人が誰であっても、見えるものは同じ", %{author: author, hidden: hidden, post: post} do
      {:ok, anon_list} = Deco.list_posts(hidden.slug)
      {:ok, mine_list} = Deco.list_posts(hidden.slug, viewer_id: author.id)
      assert Enum.map(anon_list, & &1.id) == Enum.map(mine_list, & &1.id)

      {:ok, anon} = Deco.get_post(post.id)
      {:ok, mine} = Deco.get_post(post.id, author.id)
      assert Enum.map(anon.replies, & &1.id) == Enum.map(mine.replies, & &1.id)

      # viewer で変わってよいのは、反応の `me` だけ。
      {:ok, _} = SukhiFedi.Notes.react(author, post.id, "✨")
      {:ok, anon2} = Deco.get_post(post.id)
      {:ok, mine2} = Deco.get_post(post.id, author.id)

      assert [%{name: "✨", count: 1, me: false}] = anon2.reactions
      assert [%{name: "✨", count: 1, me: true}] = mine2.reactions
      assert anon2.content_html == mine2.content_html
    end
  end

  describe "話す板" do
    setup %{author: author} do
      n = System.unique_integer([:positive])

      {:ok, talk} =
        Deco.create_deco(author, %{"slug" => "talk#{n}", "name" => "はなす板", "kind" => "talk"})

      %{talk: talk}
    end

    test "題が要らない ── ひとこと置くのに見出しを考えさせない", %{author: author, talk: talk} do
      assert {:ok, post} = Deco.post(author, talk.slug, %{"status" => "おなかすいた"})
      assert is_nil(post.title)
      assert post.content_html =~ "おなかすいた"
    end

    test "題を付けてもいい ── 要らないだけ", %{author: author, talk: talk} do
      assert {:ok, post} = Deco.post(author, talk.slug, %{"title" => "おしらせ", "status" => "本文"})
      assert post.title == "おしらせ"
    end

    test "立てる板では、いままで通り題が要る", %{author: author, deco: deco} do
      assert {:error, {:validation, %{title: _}}} = Deco.post(author, deco.slug, %{"status" => "題なし"})
    end

    test "流れは平ら ── 返信も同じ列に、書かれた順で並ぶ", %{author: author, talk: talk} do
      {:ok, a} = Deco.post(author, talk.slug, %{"status" => "ひとつめ"})
      {:ok, b} = Deco.reply(author, a.id, %{"status" => "それへの返事"})
      {:ok, c} = Deco.post(author, talk.slug, %{"status" => "みっつめ"})

      assert {:ok, flow} = Deco.list_flow(talk.slug)
      assert Enum.map(flow, & &1.id) == [c.id, b.id, a.id]

      # スレッド単位の一覧は、いまも返信を出さない ── 同じ板でも、
      # 二つの数えかたが別々に立っている。
      assert {:ok, threads} = Deco.list_posts(talk.slug)
      ids = Enum.map(threads, & &1.id)
      assert a.id in ids
      assert c.id in ids
      refute b.id in ids
    end

    test "返信は親を一段だけ抱える", %{author: author, talk: talk} do
      {:ok, a} = Deco.post(author, talk.slug, %{"status" => "この板の名前どうしよう"})
      {:ok, b} = Deco.reply(author, a.id, %{"status" => "ナタデコでいいと思う"})
      {:ok, _c} = Deco.reply(author, b.id, %{"status" => "さんせい"})

      assert {:ok, [third, second, first]} = Deco.list_flow(talk.slug)

      assert is_nil(first.parent)
      assert second.parent.id == a.id
      assert second.parent.excerpt =~ "この板の名前どうしよう"
      assert second.parent.author.acct == author.username

      # 祖父は辿らない ── 一段だけ。
      assert third.parent.id == b.id
      assert third.parent.excerpt =~ "ナタデコ"
    end

    test "親の抜粋は素の一行 ── HTML は剥いである", %{author: author, talk: talk} do
      {:ok, a} = Deco.post(author, talk.slug, %{"status" => "**ふとい**字と\n\n改行"})
      {:ok, _b} = Deco.reply(author, a.id, %{"status" => "つづき"})

      assert {:ok, [reply, _]} = Deco.list_flow(talk.slug)
      refute reply.parent.excerpt =~ "<"
      refute reply.parent.excerpt =~ "\n"
      assert reply.parent.excerpt =~ "ふとい"
    end

    test "before_id で遡れる・since_id で今日のぶんに切れる", %{author: author, talk: talk} do
      {:ok, a} = Deco.post(author, talk.slug, %{"status" => "ひとつめ"})
      {:ok, b} = Deco.post(author, talk.slug, %{"status" => "ふたつめ"})
      {:ok, c} = Deco.post(author, talk.slug, %{"status" => "みっつめ"})

      assert {:ok, older} = Deco.list_flow(talk.slug, before_id: c.id)
      assert Enum.map(older, & &1.id) == [b.id, a.id]

      assert {:ok, recent} = Deco.list_flow(talk.slug, since_id: b.id)
      assert Enum.map(recent, & &1.id) == [c.id, b.id]
    end

    test "時刻で切れる ── 「今日」の境目は読む人の時計", %{author: author, talk: talk} do
      {:ok, _old} = Deco.post(author, talk.slug, %{"status" => "きのう"})
      # 境目は投稿そのものの時刻から取る。id を打つのは DB の
      # `clock_timestamp()` なので、こちらの `DateTime.utc_now()` と
      # 突き合わせると、二つの時計のズレを測るテストになってしまう。
      Process.sleep(10)
      {:ok, fresh} = Deco.post(author, talk.slug, %{"status" => "きょう"})
      cut = SukhiFedi.Snowflake.to_datetime(fresh.id)

      assert {:ok, [row]} = Deco.list_flow(talk.slug, since: cut)
      assert row.id == fresh.id

      # id で言われたらそちらが具体的なので、そちらを採る。
      assert {:ok, both} = Deco.list_flow(talk.slug, since: cut, since_id: 0)
      assert length(both) == 2
    end

    test "反応も乗る", %{author: author, talk: talk} do
      {:ok, a} = Deco.post(author, talk.slug, %{"status" => "ひとこと"})
      {:ok, _} = SukhiFedi.Notes.react(author, a.id, "✨")

      assert {:ok, [row]} = Deco.list_flow(talk.slug, viewer_id: author.id)
      assert [%{name: "✨", count: 1, me: true}] = row.reactions
    end

    test "流れも、読む人が居なくても読める", %{author: author, talk: talk} do
      {:ok, _} = Deco.post(author, talk.slug, %{"status" => "ひとこと", "visibility" => "local"})

      assert {:ok, [row]} = Deco.list_flow(talk.slug)
      assert row.local_only == true
      assert row.content_html =~ "ひとこと"
    end

    test "変な kind は断る", %{author: author} do
      n = System.unique_integer([:positive])

      assert {:error, {:validation, %{kind: _}}} =
               Deco.create_deco(author, %{"slug" => "x#{n}", "name" => "x", "kind" => "shout"})
    end
  end

  describe "気にかけている板と、未読" do
    # 「入る」は無い。書いた板は、書いた時点で自分の場所になっている
    # ── 押して宣言するものではない（Zulip の participation）。
    # 読んでいるだけの板をどう扱うかは、板の中の詳細設定で決める。
    setup %{author: author} do
      n = System.unique_integer([:positive])
      {:ok, other} = Deco.create_deco(author, %{"slug" => "other#{n}", "name" => "あちらの板"})
      %{other: other}
    end

    defp row(author, slug), do: Deco.list_decos(author.id) |> Enum.find(&(&1.slug == slug))

    test "書いた板は、押さなくても自分の場所になる", %{author: author, deco: deco, other: other} do
      assert row(author, deco.slug).minding == false

      {:ok, _} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})

      assert row(author, deco.slug).minding == true
      # 書いていない板は、そのまま。
      assert row(author, other.slug).minding == false
    end

    test "自分が書いたあとの動きで光り、見ると消える", %{author: author, deco: deco} do
      {:ok, _} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      {:ok, _} = Deco.seen(author, deco.slug)
      Process.sleep(1100)
      {:ok, _} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "あたらしい話"})

      assert row(author, deco.slug).unread == true
      {:ok, _} = Deco.seen(author, deco.slug)
      assert row(author, deco.slug).unread == false
    end

    test "返信でも光る ── 誰かが答えたのも動き", %{author: author, deco: deco} do
      {:ok, post} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      {:ok, _} = Deco.seen(author, deco.slug)
      Process.sleep(1100)
      {:ok, _} = Deco.reply(author, post.id, %{"status" => "つづき"})

      assert row(author, deco.slug).unread == true
    end

    test "読んでいるだけの板も、詳細設定で気にかけられる", %{author: author, other: other} do
      assert row(author, other.slug).notify == "participating"
      assert row(author, other.slug).minding == false

      assert {:ok, %{notify: "all"}} = Deco.set_notify(author, other.slug, "all")
      assert row(author, other.slug).minding == true
    end

    test "しずかにすると、書いた板でも光らない", %{author: author, deco: deco} do
      {:ok, _} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      assert row(author, deco.slug).minding == true

      {:ok, _} = Deco.set_notify(author, deco.slug, "quiet")
      assert row(author, deco.slug).minding == false
      assert row(author, deco.slug).unread == false
    end

    test "設定を変えただけでは、読んだことにならない", %{author: author, deco: deco} do
      {:ok, _} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})
      assert row(author, deco.slug).unread == true

      {:ok, _} = Deco.set_notify(author, deco.slug, "all")
      assert row(author, deco.slug).unread == true
    end

    test "変な知らせかたは断る", %{author: author, deco: deco} do
      assert {:error, :bad_notify} = Deco.set_notify(author, deco.slug, "shout")
    end

    test "並びは名前順のまま ── 気にかけていても、活動量でも動かない", %{author: author, other: other} do
      {:ok, _} = Deco.post(author, other.slug, %{"title" => "題", "status" => "たくさん"})

      names = Deco.list_decos(author.id) |> Enum.map(& &1.name)
      assert names == Enum.sort(names)

      assert Deco.list_decos() |> Enum.map(& &1.slug) ==
               Deco.list_decos(author.id) |> Enum.map(& &1.slug)
    end

    test "読む人が居なければ、印は付かない", %{author: author, deco: deco} do
      {:ok, _} = Deco.post(author, deco.slug, %{"title" => "題", "status" => "本文"})

      row = Deco.list_decos() |> Enum.find(&(&1.slug == deco.slug))
      assert row.minding == false
      assert row.unread == false
    end
  end

  describe "いま話していること" do
    setup %{author: author} do
      n = System.unique_integer([:positive])
      {:ok, tourist} = LocalAccounts.create_admin("tourist_#{n}", "long-enough-pass")
      {:ok, resident} = LocalAccounts.create_admin("resident_#{n}", "long-enough-pass")
      %{tourist: tourist, resident: resident, owner: author}
    end

    test "立てた人は変えられる", %{owner: owner, deco: deco} do
      assert {:ok, view} = Deco.set_topic(owner, deco.slug, "夜ごはんの話")
      assert view.topic == "夜ごはんの話"
      assert view.topic_by.acct == owner.username
      assert view.topic_at != nil
    end

    test "その板に書いたことがある人も変えられる", %{resident: resident, deco: deco} do
      {:ok, _} = Deco.post(resident, deco.slug, %{"title" => "題", "status" => "本文"})

      assert {:ok, view} = Deco.set_topic(resident, deco.slug, "あしたの話")
      assert view.topic_by.acct == resident.username
    end

    test "通りすがりは変えられない", %{tourist: tourist, deco: deco} do
      assert {:error, :forbidden} = Deco.set_topic(tourist, deco.slug, "かってに")
    end

    test "返信しただけでも「書いた」ことになる", %{owner: owner, resident: resident, deco: deco} do
      {:ok, post} = Deco.post(owner, deco.slug, %{"title" => "題", "status" => "本文"})
      {:ok, _} = Deco.reply(resident, post.id, %{"status" => "つづき"})

      assert {:ok, _} = Deco.set_topic(resident, deco.slug, "つづきの話")
    end

    test "空にすると、誰が・いつ も一緒に消える", %{owner: owner, deco: deco} do
      {:ok, _} = Deco.set_topic(owner, deco.slug, "いちど置く")
      assert {:ok, view} = Deco.set_topic(owner, deco.slug, "   ")

      assert is_nil(view.topic)
      assert is_nil(view.topic_by)
      assert is_nil(view.topic_at)
    end

    test "長すぎる一行は断る", %{owner: owner, deco: deco} do
      assert {:error, {:validation, %{topic: _}}} =
               Deco.set_topic(owner, deco.slug, String.duplicate("あ", 121))
    end

    test "一覧にも出る ── 話す板で題を要らなくしたぶん、ここが見分けになる", %{owner: owner, deco: deco} do
      {:ok, _} = Deco.set_topic(owner, deco.slug, "夜ごはんの話")

      row = Deco.list_decos() |> Enum.find(&(&1.slug == deco.slug))
      assert row.topic == "夜ごはんの話"
      assert row.topic_by.acct == owner.username
    end
  end
end

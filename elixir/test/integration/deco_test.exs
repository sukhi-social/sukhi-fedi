# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.DecoTest do
  @moduledoc """
  natadeco の板（デコ）。器と、呼び名。

      podman compose -f docker-compose.test.yml up -d postgres nats nats-bootstrap
      MIX_ENV=test mix sukhi.migrate
      mix test --only integration test/integration/deco_test.exs
  """

  use SukhiFedi.IntegrationCase, async: false

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
end

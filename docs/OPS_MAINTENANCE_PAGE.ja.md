<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# メンテナンス中の頁(止まっている間、来た人に見せるもの)

> **意図:** 止めているあいだに来た人が、「壊れた」ではなく「いま整えています」と受け取れること。
> そして、止まる直前の公開投稿を、読むだけでも見られること(返信もお気に入りもできない、と正直に言って)。
> 運営には、止めるたびに nginx を書き換えず、戻し忘れない、一つの切り替え口を。
>
> **読み手の問題(仮説。まだ聞けていない):**
> 来た人 ─ 「落ちた? 消えた? 自分の投稿は? いつ戻る?」。
> 運営 ─ 「止めるたびに設定を触るのが怖い。戻し忘れが怖い。連合の相手に変なものを返したくない」。
> 違っていたら、教えてください。

> 状態: **実装は入った。実機では何も通していない**(nginx の規則は本物の nginx 1.24 で確かめた。§7)。
> 前提は [`RUNTIME.ja.md`](RUNTIME.ja.md) §9(ホストの nginx)と、[`OPS_QUADLET_GITOPS.md`](OPS_QUADLET_GITOPS.md)(Quadlet)。
> 「受付を止める・バックアップを取る」は別の仕事で、この文書は**その間、来た人に何を見せるか**だけを受け持つ。

## 0. 一言で

```
インターネット ─▶ nginx(ホスト)─▶ Anubis ─▶ web-next / gateway
                    │
                    │ 頁にする条件(どれか)
                    │   ① 旗(/srv/sukhi-maintenance/on)がある      … 予定した停止
                    │   ② nodeinfo が答えない(つながらない・時間切れ・5xx) … アプリが動いていない
                    │   ③ 奥が 502 / 504
                    ▼
   人の窓(GET/HEAD で text/html) → 静的サーバー(127.0.0.1:8083)に頁を取りに行く → 503 で返す
   ほかのすべて(連合・API・POST・画像)→ 短い JSON の 503(Retry-After: 300)。nodeinfo も同じ
```

- **頁は、アプリとは別の静的サーバーから取ってくる。** アプリ(Anubis・gateway・web-next)が全部止まっていても答える。
  同じ nginx の中の小さな server(`127.0.0.1:8083`、頁のファイルだけ)で、別の箱や外の静的ホスティングに替えたければ、`upstream` の一行だけ。
- **落ちているときは、落ちていると言う。** nodeinfo・webfinger・API は、古い答えを置いておいて返したりせず、503(JSON)で正直に返す。
- **旗は一つのファイル。** `scripts/sukhi-maintenance on` が立て、`off` が下ろす。nginx の設定は触らない。
- **旗がなくても、nodeinfo が答えなければ同じ頁が出る。** 予定外に落ちたときも、白紙の 502 にならない。

## 1. 来た人に何が見えるか

| だれ | 何が返るか | 理由 |
| --- | --- | --- |
| 人の窓(ブラウザで頁を開く) | 頁(HTTP 503)。言語は `?lang=` → cookie(`sukhi_locale`)→ Accept-Language の順。持っていない言語だけを挙げる人は英語、何も挙げない人は日本語 | web-next の決め方と同じ(`ENGLISH_VOICE.md`) |
| 連合の相手(`Accept: application/activity+json` など)、`/inbox` への POST、API、`/.well-known/`・nodeinfo、画像 | 頁ではなく JSON の 503(`{"error":"unavailable"}`)と `Retry-After: 300` | HTML を連合の相手に返さない。503 は「あとでまた来て」で、相手は送りなおす。**nodeinfo も、落ちているときは落ちていると返す**(置いてあった古い答えは返さない) |
| certbot の `/.well-known/acme-challenge/` | 止めない(別の location が受ける) | 止めているあいだに証明書の更新が来ても、通る |

頁の中身(三言語とも):

- 「メンテナンス中です」と、いま起きていること(任意の一行: 新しい版に入れ替え / バックアップ / 引っ越し / 不具合の修復)。
- 「お預かりしているものは、このまま守ります」。
- 戻る見込み。**時刻は出さず、「半刻ほど」のようにゆるく**(`--about 30`)。90 分を超えたら「すこし長くかかる」。**わからないときは「まだ決まっていません」と言う。**
- 止まる前の公開投稿(§5)。数(お気に入り・ブースト)も時刻も出さない。
- 頁には **script も外部ファイルも無い**(自己完結の一枚)。`noindex`、`Cache-Control: no-store`。

## 2. 置き場を作る(一度だけ)

nginx が読める場所に、箱の側のユーザー(`sukhi`)が書く置き場を作る:

```sh
sudo install -d -o sukhi -g sukhi -m 755 /srv/sukhi-maintenance /srv/sukhi-maintenance/www
# SELinux が有効なとき(Rocky / Fedora)
sudo semanage fcontext -a -t httpd_sys_content_t '/srv/sukhi-maintenance(/.*)?'
sudo restorecon -R /srv/sukhi-maintenance
```

`scripts/sukhi-maintenance` を PATH に置く(Quadlet の箱では `sukhi` ユーザーで動く)。そして、基本の頁を用意する:

```sh
sukhi-maintenance prepare    # 旗は立てない。頁だけ(予定外に落ちたとき用)
```

頁は web-next のコンテナの中の `server/maintenance-cli.ts` が作る(ことばと時間の言い方がそこにあるので、**同じ辞書を使う**)。
`SUKHI_WEB_CONTAINER`(既定 `sukhi-web-next`、`.container` の `ContainerName=`)で名前を合わせる。
コンテナに置き場を渡す必要はない ─ 作った HTML は標準出力で受けて、箱の側が書く。

## 3. nginx に入れる

`infra/nginx/` の三つを置く(nginx に `http_auth_request_module` が要る。Debian / Ubuntu / RHEL 系の nginx には入っている。`nginx -V 2>&1 | grep auth_request` で確かめる):

```sh
sudo install -m 644 infra/nginx/sukhi-maintenance.conf        /etc/nginx/conf.d/
sudo install -m 644 infra/nginx/sukhi-maintenance-server.inc  /etc/nginx/
sudo install -m 644 infra/nginx/sukhi-maintenance-gate.inc    /etc/nginx/
```

`sukhi-maintenance.conf`(http ブロック)は、頁を配る**静的サーバー**(`127.0.0.1:8083`)と診断の置き場も持っている。
[`RUNTIME.ja.md`](RUNTIME.ja.md) §9.2 の設定に、二か所だけ足す:

```nginx
server {
    listen 443 ssl;
    server_name example.tld;
    # …証明書など…

    include /etc/nginx/sukhi-maintenance-server.inc;        # ① server の直下に一度だけ

    location / {
        include /etc/nginx/sukhi-maintenance-gate.inc;      # ② アプリへ通す location の中に一行ずつ
        proxy_pass http://127.0.0.1:8082;
        # …
    }
    location /api/v1/streaming {
        include /etc/nginx/sukhi-maintenance-gate.inc;
        # …
    }
}
```

```sh
sudo nginx -t && sudo systemctl reload nginx
```

- ② を **location の中**に置くのは、certbot の `/.well-known/acme-challenge/` のような別の location まで止めないため。
- **「落ちている」の条件は nodeinfo。** アプリへ通す前に、`/_sukhi/health`(`sukhi-maintenance-server.inc`)が
  `http://127.0.0.1:8082/nodeinfo/2.0` を一度訊く。**つながらない・3 秒で答えない・5xx** なら落ちている。
  **2xx も 4xx・3xx も「動いている」**(nodeinfo が 404 でも、アプリは答えている)。
  診断の答えは 2〜5 秒だけ置くので、アクセスのたびにアプリを叩かない(置くのは診断だけで、nodeinfo 本体の答えは置かない)。
  **この `proxy_pass` の行き先を、アプリへ通す location と同じにそろえる**(例の Anubis `127.0.0.1:8082`)。そろえ忘れると、いつも「落ちている」になる ─ 最初の `nginx -t` のあと、普通に開けるか確かめる。
- アプリ自身が返した 4xx / 5xx(例: 受付停止の 503、ある投稿の 500)は、そのまま通る(`proxy_intercept_errors` は既定の off のまま)。
  「このリクエストだけ失敗した」と「サーバーが落ちている」を混ぜない。頁にするのは、旗・nodeinfo の診断・nginx 自身の 502/504 だけ。
- 頁を取りに行った静的サーバーが答えない・頁のファイルが無いときは、JSON の 503 に落ちる(白紙にならない)。
- 置き場・診断の行き先・静的サーバーのポートを変えるなら、三つのファイルの `/srv/sukhi-maintenance`・`127.0.0.1:8082`・`127.0.0.1:8083` を書き換える(nginx は環境変数を読めない)。

## 4. 止めるとき・戻すとき(順番)

```sh
# 1. 受付を止める             ← 別の仕事(受付停止とバックアップ)。アプリは起きたまま、書き込みだけ止める
# 2. 頁に切り替える(止める前の公開投稿を写す)
sukhi-maintenance on --why backup --about 30        # 端末からは (Y/N)? と訊く。自動化では --yes
# 3. バックアップ・コンテナを止める・作業
# 4. コンテナを起こす・ヘルスが通るのを確かめる
# 5. 頁を下ろす
sukhi-maintenance off
```

- **`on` は止める前に。** 投稿の写しは、web-next と gateway が起きているあいだにしか作れない。
  作れなかったときは、警告を出して**一覧なしで続ける**(旗を立てるのが先)。
- **受付停止の側から呼ぶときの約束:** 終了コード 0 = 旗が切り替わった(頁を作れなかったときも 0。警告は標準エラー)/
  1 = 旗を切り替えられなかった / 2 = 使いかたの誤り。`on` も `off` も何度呼んでもよい(`--about` を変えて呼びなおすと、頁が更新される)。
  理由は `update | backup | migration | repair` の四つだけ(頁は三言語に訳してあり、自由な文は載せない)。
- **`off` は、写しを消す**(§5)。基本の頁(一覧なし)に作りなおす。web-next が起きていなくて作りなおせないときは、写しの入った頁ごと消す
  (消した投稿を残さないほうを選ぶ)。そのあとの予定外の落ち方は、白紙でなく JSON の 503 になるので、起きたら `prepare` を。
- 外から確かめるなら `SUKHI_MAINT_URL=https://example.tld/` を付ける(`on` のあとに 503、`off` のあとに 503 でないことを見る)。
- 状態は `sukhi-maintenance status`。旗の中身(いつから・理由・見込み・写しの件数)は `/srv/sukhi-maintenance/on` に `key=value` で入る。

GitOps の同期([`OPS_QUADLET_GITOPS.md`](OPS_QUADLET_GITOPS.md) §3.3)が `try-restart` するときに、この頁を挟むかは決めていない(§6)。
いまは「gateway が短く止まる」ことを目安としているので、**最初は挟まなくても、奥が答えない間は同じ頁が出る**。

## 5. 止まる前の投稿の写し(読むだけの一覧)

- **何を写すか:** このサーバーの公開タイムライン(`/api/v1/timelines/public?local=1`、認証なし)から、最大 30 件。
  **公開の、その人自身の投稿だけ。** ブースト・返信・引用、非公開・未収載・ダイレクトは外す(前後が欠けると読めないので)。
  画像だけの投稿は、文字が無いので載らない。注意書き(CW)とセンシティブは、折りたたんで出す。
- **文字だけにする。** 本文の HTML はタグを持ちこまず、段落を残した文字にして、出すときに必ずエスケープする(リンクも画像も本文からは出ない)。
  この「文字だけにする」は `web-next/server/maintenance.ts` の一か所。
- **いつまで残るか:** 止めているあいだだけ。**`off` で消える。** 止めている間に消された投稿が、あとまで残らないように。
  (止めている間に消された投稿は、その間は写しに残る。短い間のことだが、事実として書いておく。)
- 頁のことば(三言語)は `web-next/server/locales/maintenance.ts`。声は [`ENGLISH_VOICE.md`](ENGLISH_VOICE.md) と [`KINDNESS.md`](KINDNESS.md)。

## 6. まだ・決めていないこと

1. **実機では未確認。** 初回は、`prepare` → 外から `Accept: text/html` で 503 を確かめる(旗なしでアプリを止めて 502 → 頁になるか)→ `on` → `off` の順に手で。
2. **規約・プライバシーには書かない案**(ひなたの問い「書く必要あるかな?」への答え。最終は人)。写しは、すでに公開されているものを、同じサーバーの中に、止めている間だけ置く。
   プライバシー §3 の「サーバーに保存される情報」と、公開したものを「公開した目的の範囲で扱う」の中に収まり、`off` で消える。
   使いみちが変わる(広告・解析・外部への提供)わけでもない。広げるときは、そのとき書く。
3. **GitOps の同期が、更新のたびに `on` / `off` を呼ぶか。** 呼ぶなら `sukhi-setup` の同期スクリプトに二行。
4. **画像・アイコンは写さない**(文字だけ)。要るかは、使ってから。
5. **自動で戻る(JS)は入れていない。** 開いたままの頁が勝手に動かないように。「ひらきなおしてください」と言う。
6. **アプリ側の受付停止との合わせ込み**(別の仕事)。受付停止中の 503 は、nginx では頁にしない(アプリのものがそのまま通る)。人にも頁を見せたいなら、
   受付停止の側が `on` を呼ぶのが一番ふつうの形。
7. 言語は、イタリア語・ドイツ語・フランス語を足すときに、`locales/maintenance.ts` にも一行ずつ(`ENGLISH_VOICE.md` の末尾)。

## 7. 確かめ方

```sh
make test-nginx          # infra/nginx/test.sh: 本物の nginx に規則を読ませ、偽のアプリを後ろに立てて 四十通りほどを見る(診断の置きを待つので 30 秒ほどかかる)(nginx が無ければ skip)
make test-maintenance    # scripts/sukhi-maintenance_test.sh: 偽のコンテナ道具と偽の gateway で、on / off / 失敗のときを通す
cd web-next && pnpm test # 頁の中身(文字だけにする・エスケープ・三言語がそろう)は test/maintenance.test.ts
```

`test-nginx` が見ているもの: 旗があれば奥が動いていても 503 / 奥が止まれば同じ頁 / アプリ自身の 503 は通る /
言語の決め方(`?lang=` → cookie → Accept-Language)/ ActivityPub の取得・`/inbox` の POST・API・画像には頁でなく JSON /
certbot の道は止めない / 頁が一枚も無くても JSON の 503 /
nodeinfo だけが壊れたとき(= 条件)に頁になる・nodeinfo が 404 なら動いているとみなす・アプリ自身の 5xx は通る・
nodeinfo も落ちているときは正直な 503(古い答えは返さない)・静的サーバーは頁のファイルしか返さない。

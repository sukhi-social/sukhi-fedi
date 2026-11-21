# sukhi-web-next

sukhi-fedi の web を、**Unpoly + Alpine.js の MPA** で作りなおしたもの。
`sukhi-web-next`(SvelteKit の SPA)と、sukhi-fedi にあった旧 SPA(`web/`、いまは無い)を読んで、同じことばと見た目を借りた。

サーバ(郵便局)が、gateway(Elixir)の `/api/v1` を呼んで、HTML を組み立てて返す。
ブラウザ側の JS は、`public/js/app.js` ひとつだけ(Unpoly の設定・Alpine の小さな部品・字の着替え)。

## 動かす

Node 24(型をそのまま読むので、サーバーにビルドは要らない)と pnpm。
ビルドは、service worker(`sw/sw.js`、Serwist)を `public/sw.js` に束ねる一つだけ。`dev` `dev:mock` `test` が自分で呼ぶ(Docker は build stage)。

```
pnpm install
pnpm run build:sw   # sw/sw.js → public/sw.js(git には入らない)
pnpm run dev:mock   # http://localhost:5174 — 偽の gateway(:4010)といっしょに、入った状態で立つ
pnpm run dev        # 本物の gateway(GATEWAY_URL、既定 http://localhost:4000)に向けて立つ
pnpm test
```

| 環境変数 | 意味 |
|---|---|
| `PORT` | 待ち受け(既定 5174) |
| `GATEWAY_URL` | gateway のもと |
| `PUBLIC_ORIGIN` | ブラウザから見えるこのサイトの origin(OAuth の戻り先になる) |
| `COOKIE_SECURE=1` | https の裏に置くとき |
| `SITE_NAME` | ナビ・入口の帯・`<title>` の末尾に出るサイトの名前(既定 `sukhi-fedi`) |
| `SITE_LOGO` | その横のロゴ画像。`/…` のパスか `https://…` の URL(既定 `/favicon.png`)。ほかの書きかたは既定に戻す。image を焼きなおさずに替えるには、`data/brand/` にファイルを置き(コンテナなら `/app/data/brand/`)、`/brand/<ファイル名>` を書く |
| `SITE_THEME` | 見た目のテーマ。`about`(既定。about.sukhi.social の色)か `ink`(紙とインク。web にあった見た目)。知らない名前は `about`。頁の `<html data-theme>`・`theme-color`・manifest の色が、いっしょに替わる(`server/theme.ts`) |
| `ABOUT_URL` | はじめての人の行き先(既定 `https://about.sukhi.social`。空ならここの入口) |
| `POST_DELAY_MIN` | 投稿が上がるまでの余白(分、既定 15 = 約四半刻。0 ですぐ上がる) |
| `NOTIFY_HOLD_MIN` | 「反応」の通知を置く時間(分、既定 60)。gateway に `hold_minutes` として毎回添える |
| `ME_TTL_MS` | 手元にひかえた「自分」(翻訳やタイムラインなどの設定を含む)を gateway に引きなおすまでの間(ms、既定 15000)。別の端末・別のタブで変えた設定が、この間のうちに届く。設定の頁は、開くたびに引く |
| `SUKHI_DEV_TOKEN` | dev のときだけ。入った状態から始める(mock 用) |

## つくり

```
server/
  main.ts        入り口
  http.ts        文脈(Ctx)・ルーター・静的ファイル・gateway への通し道
  gateway.ts     /api/v1 を呼ぶ(トークン付与・refresh・Link の次ページ)
  session.ts     トークンはここ(サーバ)。ブラウザには札(sukhi_sid)だけ
  routes/        auth(入口・入る・はじめる)/ read(読む)/ write(書く・押す・通知)/ requests(フォロー申請に答える)/
                 settings(プロフィール)/ security(ログインと安全・あいことば)/ migration(引っ越し)/ data(フォロー等の CSV)/
                 rooms(ふたりの部屋)/ clips(自分あてのメモ置き場)/ map(路線図)/ draft(書きかけ)
  maintenance.ts / maintenance-cli.ts   アプリが止まっている間に nginx が返す「メンテナンス中」の頁を作る(docs/OPS_MAINTENANCE_PAGE.ja.md)。ここは配らない
  views/         HTML(html`` は差し込みを自動でエスケープ。raw() だけがそのまま)
  time.ts        時計の針を外した、うつろいのことば
sw/              service worker(Serwist)。scripts/build-sw.mjs が public/sw.js に束ねる
public/          css(sukhi-web-next から借用)・app.js(Unpoly・Alpine)・pwa.js(SW 登録・オフラインの帯・知らせの入り切り)
mock/            偽の gateway(sukhi-web-next/shots の mock を借用)
```

- `/admin`(管理ページ。設定の「管理ページへ」が、トークンをサーバ側で /admin/login に置いて cookie を渡す)・`/oauth/` `/api/` `/terms` `/privacy` `/static/` `/uploads/` `/proxy/` `/.well-known/` などは、gateway にそのまま通す。
  この郵便局が、同じ origin の前に立つ前提。
- Unpoly は、いつも `<main>` を差し替える。入る・出る・ことば替えだけは、ふつうのフォーム(フルリロード)。
- **関所(`/check`)**: anubis が PoW を解かせるのは `GET /check` だけ(`config/anubis/botPolicies.yaml`)。
  ログインは一段目(合言葉・メールのコード・2FA)のあとで、加入はメールのコードの確認のあとで、
  `/check?intent=login|signup` へ送る。**メールのコードを送るのも、この関所の後**(`login-email` と、加入の
  最初の段 ── 元の web の「メールは Anubis の後」)。通れた人だけがここへ届き、そこで初めてコードが送られる・
  OAuth が始まる・アカウントが作られる。加入のやりかけ(ハンドル・メール・招待コード)は session に置き、
  `/signup` に戻ったとき埋める(同意は埋めない)。何をするかは session の `check` に置いてあり(URL の `intent` は合図にすぎない)、
  一度きり ── リロードしても二度は始まらず、何も無い人が来たら `/login` か `/signup` に戻す。
  anubis を前に立てない開発(`pnpm run dev:mock`)でも、そのまま通る。

## アプリとして(PWA)

ストア不要(ホーム画面に追加)。軽く、落ちていても読みかえせて、返信やフォロー申請は端末にそっと届く。

- **service worker**(`/sw`。Cloudflare が `.js` に足す max-age を避けて、拡張子なしで配る)
  - 字・画像のような、中身で URL が決まるものは、置いたらそのまま(CacheFirst)。
  - 読む頁(おうち・タグ・プロフィール・投稿)は、つながるなら新しいものを、だめなら置いてあるものを(NetworkFirst、3 日・40 まで)。
    通知・検索・設定・書く頁は置かない。`/check` `/oauth` `/api` には触らない。置くかどうかは `sw/sw.js` の `KEEP_PAGES` 一か所。
  - 落ちているときは、SW の中の一枚(`/offline` のような頁はない)。責めずに「もういちど」を置く。つながったら、自分で戻る。
  - 出る(logout)ときは、置いた頁・画像と、この端末の知らせの購読を、頁側(pwa.js)が片づけてから出る。
- **知らせ(Web Push)**: gateway の `/api/v1/push/subscription` につなぐ(`routes/push.ts`。トークンはサーバにあるので、ブラウザはここを通る)。
  - 鳴っていい種類は gateway が決める(`direct_types` = 返信・フォロー申請)。web-next は足さない。お気に入り・ブーストでは鳴らない。
  - 本文も数もバッジも出さない。見ている窓があれば鳴らさない。同じ人は一つに畳む。許可は、設定で人が入れたときだけ訊く。
  - gateway の購読はアカウントに一つ。別の端末で入れると、そちらに替わる。
- **ネイティブ風**: Unpoly で頁をつなぐ(MPA のまま、`<main>` だけ差し替え)。操作の部品からだけ、長押し・選択・ダブルタップ拡大・タップの光を外す
  (本文と画像は選べるまま)。ホーム画面から開いたときだけ、引っぱって更新・端のバウンドを止める。つながっていない帯は `<main>` の外。
- **新着の帯**: タイムライン(ホーム・みんな・ご近所・タグの先頭頁)の上に、新しい投稿が届いたときだけ「あたらしい投稿があります」の帯が、そっと出る。
  押すまで列は動かない(押すと、いちばん上から取りなおす)。リロードの無い PWA でも、ふつうのブラウザでも、同じ帯。
  `GET /timeline/fresh?since=<先頭の id>` が「あるか」だけ(204 か 200)を返す ── 数も中身も返さない。見えているときだけ訊き、
  間合いは、ホーム画面から開いたとき 60 秒・ブラウザ 3 分、Save-Data では定期の問い合わせをしない(`public/js/app.js` の `[data-fresh]`)。
- **フィルター**: 「フィルター」の窓で、画像のみ・ブーストを隠す(ホームだけ)・センシティブを隠す。ホームでは「これをデフォルトにする」で、
  いまの絞りこみを gateway の `home_filter` に置く(端末をまたぐ)。ホームを素で開いたとき(`filtered=1` が無いとき)に、これがかかる。
  フォームから来たときは `filtered=1` が付き、外した絞りこみも、そのまま守る。
- **ブーストの行**: 左から、ブーストした人のアイコン・(ブーストした人の名前)・ブーストの印・ブーストされた人のアイコン・二行までの内容。
  名前は、設定の「タイムラインの見え方」(`boost_hide_name`)で隠せる。読み上げには「○○が、△△の投稿をブースト」の一文(名前を隠すときは「△△の投稿を、ブースト」)。
- **Web API**: manifest の `share_target`(他のアプリの「共有」→ `/compose?text=&url=`)・`shortcuts`(書く・通知)。
- アイコンは about.sukhi.social のロゴ(橙)。192 / 512 / maskable(角まで橙)/ apple-touch / favicon。

## sukhi-web-next との、意図した違い

- **数を出さない**: お気に入り・ブースト・リアクション・フォロワー・投稿の数。通知は、待っている人のぶんだけ(下)。
- **通知のしるし**: ナビの通知のそばに、二つだけ。返信・フォロー申請(direct)の未見は、数字そのまま。お気に入り・ブーストなど(ambient)は、
  数字ではなく、数で育つかたち(、→ 輪 → w → Λ → A → 木。境いは 1 / 3 / 6 / 11 / 19)。赤も丸も付けない。数え方は `server/notify.ts` 一か所
  (最新の一頁 40 から数える)。置き場は空で来て、頁が描かれたあとに `public/js/app.js` が `GET /notifications/unseen` で満たす(頁を待たせない)。
- **どこまで見たか**: gateway の marker(`notifications`)が一本の正本で、層ごとの印は持たない(別の端末で見たものを、また「新着」と数えない)。
  通知の頁を描くだけでは動かさない(GET は書かない。`up-preload` が先に開いても動かない)── 見えたとき `[data-mark-seen]` が `POST /notifications/seen`。
  頁には、来たときの印を `since` でタブ・「もっと読む」へ引き継いで、「新しい通知は、ここまで」の線を引く(見たあとも、線は動かない)。
  はじめて(印が無い)は「いま」を起点にする。一件も無いなら `0` を置く(最初の一件を、見たことにしない)。
- **通知のライブ更新**: `GET /notifications/stream`(SSE)が gateway の `streaming/user/notification` を読み、direct のぶんだけ、中身なしの
  `event: direct` を渡す(ambient は流さない。かたちは、頁と頁の境でだけ動く)。ブラウザは、それを合図に数だけ取りなおす ── 本文は、この道を通らない。
  gateway に届かないときは `200` + `retry: 60000` で閉じる(EventSource は `200` でないと繋ぎ直さない)。`401` は、そのまま `401`。
  呼び鈴の形(荷物ではない・繋ぎ直し・心拍)は `server/sse.ts` 一か所で、通知も部屋も、ここを通る。
- **部屋のライブ更新**: ふたりの部屋を開いているあいだ、`GET /rooms/:id/stream`(SSE)が、この部屋に何か起きたとき、中身なしの `poke` を鳴らす。
  向こうは gateway の WebSocket(`stream=direct`)で、この郵便局が `Authorization: Bearer` を握手の header に付けて開く(`server/direct.ts`。
  ブラウザは WebSocket に header を付けられず token を URL に乗せるしかないが、ここなら URL に出ない)。鳴ったら、ブラウザは
  `GET /rooms/:id/talk`(ログの箱の中身だけ。読んだ印も付く)を取りなおして差す ── 書きかけの返事には、ふれない。
  60 秒の見直しは残す(管が死んでいることに、こちらからは気づけない)。裏に回ったら畳み、戻ったら開いて一度訊く。
- **時間は、うつろいで**: 「今日の昼下がり」「昨日の宵」「秋の夜ふけ」。分・秒は言わない。
- **見直しの余白**: 投稿は `scheduled_at` で約四半刻あとに上がる。そのあいだは「お預かり」として、とりやめられる。
- **反応は、ポツポツ**: お気に入り・ブーストなどの通知は、`NOTIFY_HOLD_MIN` 置いてから出し、同じ投稿への反応は一つにまとめる。返信・フォロー申請はすぐ。置くのもまとめるのも gateway の仕事で(アカウントごとの設定がある。docs/MASTODON_API.md の「Pace」)、この郵便局は、設定にかかわらず `hold_minutes` と `grouping` を添えて呼ぶ。
- **列に終わりがある**: 「もっと読む」(Unpoly が後ろに足す)か、「ここまで、です。」のどちらかが、かならず末尾に付く。
- トークンは、ブラウザの localStorage ではなく、サーバのセッション。
- ログインの要素(メール・2FA・パスキー・端末・あいことば)は、gateway が bearer を受けず、ブラウザの `session_token` cookie だけを見る。
  この郵便局は、その cookie を一本だけ添えて呼ぶ(`gwCookie`)。cookie が無い・切れていれば、フォームを出さずに「入りなおして」。

## web にあって、ここに来たもの

旧 SPA(`web/`)は消した。旧 web でできたことは、ここでもできる。

- **Clips**(`/clips`。どこからもリンクしない ── 旧 web も、直 URL だけ): 自分あての会話(`accounts` が空)を、メモ置き場に使う頁。
  古い順で、下から読む。まだ一通も無ければ、最初の一通が部屋を作る。
  - 置く(`POST /clips`)は、頭に自分の `@` を付けた DM を、直前の一通への返信として(同じ部屋に入る)。お預かり(四半刻の余白)はかけない。
    ファイルは四つまで、種類は問わない。置き場は `routes/clips.ts`、一枚の姿は `views/clips.ts`。
  - 宛名(頭の `@`・言及だけの末尾の段落)は、見せるときに外す(`withoutAddress`)。コピーの字は、外したあとの全文。
  - ピンは 📌 のリアクション。押すのは、ふつうのリアクションと同じ道(`POST /statuses/:id/react`)── 返るのは、この頁の一枚の姿。
  - `?q=` で探す(gateway の検索)・`?pinned=1` でピンだけ(開いた一頁のなか)・`?max_id=` でもっと古いほう(一頁 20 件)。
  - ライブ更新は、ふたりの部屋と同じ呼び鈴。`GET /clips/stream`(SSE)が `poke` を鳴らし、ブラウザが `GET /clips/talk?since=<開いたときの先頭>`
    (それより後に届いた分だけ、古い順)を取りなおして、下に足す。読んでいるところは動かさない。
- **路線図**(`/map`。ナビには無く、入っていない人の入口から行ける。入っていない人にも開いている): `GET /map` が頁、`GET /map/live` が 30 秒ごとの取りなおし
  (領域だけを返し、絵の差しかえは `public/js/app.js`)。数字は gateway が 5 秒覚えている ── キャッシュは、そこ一か所。はかれなければ、線路だけ。
- **書きかけ**(ふつうのノート): 書く欄が、手を止めたあとに `POST /compose/draft` で、gateway の `/api/i/notes/drafts` へ置く(一アカウントに一つ。連合しない)。
  開いたとき(`GET /compose`)に戻り、送れたとき(`POST /compose`)に畳む。戻るのは、はじめの一通だけ ── 返信・引用・記事・共有からの書き出しには、戻さない。
  gateway の口は `routes/draft.ts` 一か所。置きそこねても、書くことは止めない。記事の書きかけは、これとは別で、この端末の localStorage だけ。
- **テーマ**: `SITE_THEME`(上の表)。`about` が既定、`ink` は旧 web の紙とインクの見た目(`server/theme.ts`・`public/css/theme-ink.css`)。

## まだ

ない: 部屋から投稿を差し出す(web にも、無かった)。

`TODO.md` に、入口の行き先についての、次の予定がある。

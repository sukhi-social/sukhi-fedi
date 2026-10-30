# sukhi-web-next

sukhi-fedi の web を、**Unpoly + Alpine.js の MPA** で作りなおしたもの。
`sukhi-web-next`(SvelteKit の SPA)と `sukhi-fedi/web` を読んで、同じことばと見た目を借りている。

サーバ(郵便局)が、gateway(Elixir)の `/api/v1` を呼んで、HTML を組み立てて返す。
ブラウザ側の JS は、`public/js/app.js` ひとつだけ(Unpoly の設定・Alpine の小さな部品・字の着替え)。

## 動かす

Node 24(型をそのまま読むので、ビルドは要らない)と pnpm。

```
pnpm install
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
| `ABOUT_URL` | はじめての人の行き先(既定 `https://about.sukhi.social`。空ならここの入口) |
| `POST_DELAY_MIN` | 投稿が上がるまでの余白(分、既定 15 = 約四半刻。0 ですぐ上がる) |
| `NOTIFY_HOLD_MIN` | 「反応」の通知を置く時間(分、既定 60)。gateway に `hold_minutes` として毎回添える |
| `SUKHI_DEV_TOKEN` | dev のときだけ。入った状態から始める(mock 用) |

## つくり

```
server/
  main.ts        入り口
  http.ts        文脈(Ctx)・ルーター・静的ファイル・gateway への通し道
  gateway.ts     /api/v1 を呼ぶ(トークン付与・refresh・Link の次ページ)
  session.ts     トークンはここ(サーバ)。ブラウザには札(sukhi_sid)だけ
  routes/        auth(入口・入る・はじめる)/ read(読む)/ write(書く・押す・通知)/
                 settings(プロフィール)/ security(ログインと安全・あいことば)/ migration(引っ越し)
  views/         HTML(html`` は差し込みを自動でエスケープ。raw() だけがそのまま)
  time.ts        時計の針を外した、うつろいのことば
public/          css(sukhi-web-next から借用)と app.js
mock/            偽の gateway(sukhi-web-next/shots の mock を借用)
```

- `/oauth/` `/api/` `/terms` `/privacy` `/static/` `/uploads/` `/proxy/` `/.well-known/` などは、gateway にそのまま通す。
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

## sukhi-web-next との、意図した違い

- **数を出さない**: お気に入り・ブースト・リアクション・フォロワー・投稿の数。通知の未読の数・点・バッジも。
- **時間は、うつろいで**: 「今日の昼下がり」「昨日の宵」「秋の夜ふけ」。分・秒は言わない。
- **見直しの余白**: 投稿は `scheduled_at` で約四半刻あとに上がる。そのあいだは「お預かり」として、とりやめられる。
- **反応は、ポツポツ**: お気に入り・ブーストなどの通知は、`NOTIFY_HOLD_MIN` 置いてから出し、同じ投稿への反応は一つにまとめる。返信・フォロー申請はすぐ。置くのもまとめるのも gateway の仕事で(アカウントごとの設定がある。docs/MASTODON_API.md の「Pace」)、この郵便局は、設定にかかわらず `hold_minutes` と `grouping` を添えて呼ぶ。
- **列に終わりがある**: 「もっと読む」(Unpoly が後ろに足す)か、「ここまで、です。」のどちらかが、かならず末尾に付く。
- トークンは、ブラウザの localStorage ではなく、サーバのセッション。
- ログインの要素(メール・2FA・パスキー・端末・あいことば)は、gateway が bearer を受けず、ブラウザの `session_token` cookie だけを見る。
  この郵便局は、その cookie を一本だけ添えて呼ぶ(`gwCookie`)。cookie が無い・切れていれば、フォームを出さずに「入りなおして」。

## まだ(縦に一本、のあと)

入口・入る・はじめる・タイムライン・タグ・投稿の詳細・プロフィール・書く・通知・さがす・設定(プロフィール・
ログインと安全〔メール・2FA・パスキー・端末・あいことば〕・引っ越し)まで。
ない: 設定の掃除・BOT・アカウントを閉じる /  lists / clips / map / messages(DM)/ bookmarks / favourites の頁 /
絵文字ピッカー / メンションの補完 / 下書きの保存 / 投票 / プロフィールの編集・ミュート・ブロック・私的メモ /
Service Worker・Push。

`TODO.md` に、入口の行き先についての、次の予定がある。

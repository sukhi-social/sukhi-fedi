# ui-lab

web-next の見た目を、**作りこむ前に、並べて比べる**ための作業机。
サーバのコードも gateway もいらない。本物の CSS・字・Unpoly・Alpine がそのまま乗った頁を、
HTML だけで書いて、スマホ/デスク・明/暗・場面を切り替えながら見る。

目的は「十分に考えて、確かめて、細かいことは逃す」こと。
投稿の中身・API・認証は、わざと省く。確かめたいのは、**いつ・どこに・どんな順で出るか**。

## 使う

```
make ui-lab          # http://localhost:5180(= cd web-next/ui-lab && node serve.mjs)
```

左の一覧で名前を押すと A に、**B** を押すと右に並ぶ。上の帯で、画面(スマホ/タブレット/デスク)・明暗・時計・
モックごとの「場面」を切り替える。状態は `#hash` に入るので、URL を渡せば同じ並びが開く。

一覧に出るもの(フォルダを足すだけ。登録はいらない):

| どこ | 何 |
|---|---|
| `mocks/<名前>/index.html` | ここで書くモック。下の「書く」 |
| `external/<名前>/dist/` | `import.mjs` で取りこんだ、よその作りのモック(git には入れない) |
| `lab/live.json` | いま動いている web-next(`pnpm run dev:mock`、:5174)の頁。比べる相手 |

## 書く

`mocks/<名前>/index.html` の先頭を `<!--lab:shell-->` にすると、本物のナビ・`<head>`(CSS・JS)が付く。
**`<main>` の中身だけ**を書けばよい。先頭の `<title>` `<meta>` `<link>` `<style>` `<script>` は head に入る。

```html
<!--lab:shell-->
<title>ホーム + 到着の帯(案)</title>
<meta name="lab:desc" content="一行の説明">
<meta name="lab:scenes" content="fresh=便りが届いている;night=夜ふけ">   <!-- 場面: id=ラベル;… -->
<meta name="lab:nav" content="home">                                       <!-- ナビの印: home|compose|notifications|search|none -->
<style>html:not([data-s~=fresh]) .only-fresh { display: none }</style>     <!-- 旗は <html data-s="…"> -->
<section class="only-fresh">…</section>
```

- **場面**: `?s=fresh,night` → `<html data-s="fresh night">`。CSS は `html[data-s~=fresh]`、JS は `lab.has('fresh')`。
  状態の違い(あり/なし/空/夜)を、頁を何枚も書かずに並べられる。
- **時計**: `?now=22:30` → `lab.now()`。あいさつ・「次のお届け」のような、時で変わる所を確かめる。
- **リンク・送信は動かない**。押すと行き先だけ出る(`mock.js`)。
- 色・間・字は `tokens.css` の変数から。決まったら、`components.css` に移して、`views/*.ts` で HTML を組む。
  `/assets/…` の URL は本物と同じなので、HTML はそのまま移せる。
- 明暗: `tokens.css` の暗い色は端末まかせ(`@media`)。ここでは serve.mjs が同じ値を `[data-theme=dark]` にも出す
  (値は増やしていない。元の一か所を写すだけ)。

## 取りこむ(他のエージェント・Figma Make などの React + Vite)

```
cd ui-lab && pnpm install --ignore-workspace --ignore-scripts   # 最初に一度
node import.mjs ~/Downloads/モック.zip lobby-figma               # → external/lobby-figma/dist
```

zip は**信頼できない入力**として扱う: 中の vite.config・scripts は走らせず(束ねる設定は import.mjs の中だけ)、
依存は ui-lab の node_modules から引く。一行の型リテラルから `;` が落ちている形(`{ a: string b: string }`)だけは、
構文エラーで止まったときに限って直して、直した行を出す。外の画像・字を引く所は、オフラインだと欠ける。

## 写真を撮る(目で比べる)

```
node shot.mjs home-arrival --scene fresh,waiting            # shots/ に、スマホとデスクの全頁
node shot.mjs --compare home-arrival live:/ --device phone  # ギャラリーと同じ並びで A|B を一枚に
```

`--theme light,dark`、`--now 22:30`、`--no-full` もある(先頭のコメント)。playwright は、入っていれば使う。
撮る前に `node serve.mjs`(live を撮るなら `pnpm run dev:mock` も)を立てておく。

## しないこと

- 本番の頁の代わりにはならない。形・順・間合いを決める所まで。決まったら `server/views/` に移して、`test/` を足す。
- モックの文言は仮。ことばの正は `server/locales/`。

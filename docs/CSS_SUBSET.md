<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# HTML と CSS の「使える部分」

iced・egui・Jetpack Compose・SwiftUI は、CSS のカスケードを持たない。それでも、
画面は組める。そこから借りて、web の側で **使う機能を絞る**。

- **新しい機能は、積極的に受け入れる**(下の「新機能の受け入れ」)。
- **古い CSS は書かない**。**打ち消し(override)を強いる書き方も、書かない**。
- 規則は `web/scripts/css-subset.mjs` が機械で見る(`pnpm run css-check`)。

## 0. 四つの枠組みから借りるもの

| 枠組み | 借りること(一次資料で確かめた点) | web での形 |
|---|---|---|
| **iced** | 寸法を `Length` の四つで言う: `Fill`(残りを全部)・`FillPortion(n)`(残りを比で)・`Shrink`(最小)・`Fixed(px)`。`Row`(横)・`Column`(縦)・`Container`(中で寄せる)が基本の部品。`Themer` で、中の部品だけに別のテーマを当てる。(docs.rs/iced) | §2 の寸法の言い方と、五つの部品。テーマは、部品の外から値を渡す(§1-c) |
| **egui** | 即時モード。部品は貯めず、毎回、置く。**セレクタも、詳細度も無い**。スタイルは `Ui` に直接書き、`ui.scope(...)` の中だけに効き、出れば**元に戻る**。(docs.rs/egui) | 変更は、その部品の中だけ(§1-a)。出たら終わる = `@scope` か、部品の境界 |
| **Jetpack Compose** | **modifier の順序に意味がある**(`padding` のあとに `clickable` だと、余白は押せない)。**margin の modifier が無い**。**制約は親から子へ**渡り、子は守る。(developer.android.com/develop/ui/compose/modifiers) | 外の余白を持たない(§1-b)。子は、自分の幅を決めない |
| **SwiftUI** | 「各 view は、ある状態で何を見せるかの記述を持つ」。見た目は modifier で足し、よく使う束は `ViewModifier` にまとめる。(developer.apple.com の View fundamentals) | 部品 = 状態から決まる記述。よく使う束は、クラスや `@layer` の部品にまとめる |
| (未確認) | SwiftUI の **Environment**(値を下へ流す)と、Compose の `CompositionLocal` は、私の知識で、今回は一次の頁で確かめていない | 「環境」= カスタムプロパティ(§1-c) |

## 1. 三つの原則

### a. 打ち消しが要らない — 詳細度を揃える
- すべての規則は、**クラス一つ(0,1,0)か `:where()`(0,0,0)**。
- **`!important` は書かない**(例外: `prefers-reduced-motion` の view transition 擬似要素だけ)。
- **`#id` セレクタは書かない**。セレクタは**二つの塊まで**(`.a .b`)。部品の外へ手を伸ばさない。
- 全体の CSS(`src/styles/*.css`)は、すべて **`@layer` の中**に置く。Svelte の部品の
  `<style>`(scoped)は**層の外**なので、層の中の規則に、**詳細度の勝負なしで勝つ**。
  「全体の `.chip` を、部品の `.chip` が上書きしたい」が、順序と層だけで解ける。
  ```css
  @layer reset, tokens, primitives, base;   /* 層の順序を、一か所で宣言する */
  ```
- Svelte の **`:global()` で、よその部品の中を書き換えない**。見た目を変えたいときは、
  部品が**カスタムプロパティを受け取る**(§1-c)。

### b. 部品は、自分の中だけを決める — 外の余白を持たない
- Compose に margin が無いのと同じ。**外の余白は、親の `gap` と `padding`** で決める。
- `margin` は、**`auto`(寄せる・押す)と `0`** だけ。`margin-inline: auto`(中央)、
  `margin-inline-start: auto`(Spacer のように押す)。
- 子は、自分の幅を決めない。**親が渡す**(§2 の寸法)。

### c. 値は「環境」から来る — カスタムプロパティ
- 色・間隔・大きさ・層(`z-index`)・動きは、**カスタムプロパティ**(`tokens.css`)から読む。
- **生の色(`#`・`rgb()`・`hsl()`)は、`tokens.css` の外に書かない**。色は `oklch()` と
  `color-mix()`、明暗は `light-dark()`。
- `z-index` は数字を書かない。`--layer-sticky` のような名前で読む。
- 値を渡すときは、`style="--n: 3"` のように**カスタムプロパティだけ**を、インラインに置いてよい。
  `style="margin-top: …"` のような、普通のプロパティのインラインは書かない。
- 動く値は `@property` で型を登録する(補間と、初期値が効く)。

## 2. 部品は五つ(iced の Row / Column / Container にならう)

| 部品 | 役割 | CSS の芯 |
|---|---|---|
| `Stack` | 縦に積む(Column) | `display: flex; flex-direction: column; gap: var(--gap)` |
| `Row` | 横に並べる | `display: flex; gap: var(--gap); align-items: …` |
| `Box` | 中に余白と面を持つ(Container) | `padding: var(--pad); background: …` |
| `Grid` | 二次元・列を揃える | `display: grid`(`subgrid` を使ってよい) |
| `Spacer` | 残りを押し広げる | `flex: 1`、または `margin-inline-start: auto` |

**寸法の言い方(iced の `Length`)**

| iced | CSS |
|---|---|
| `Fill` | `flex: 1 1 0`(主軸)/ `inline-size: 100%` |
| `FillPortion(n)` | `flex: n 1 0` |
| `Shrink` | `flex: none` / `inline-size: fit-content` |
| `Fixed(px)` | `inline-size: var(--size-…)`(トークンの名前で) |

幅を決めるのは、**画面の幅ではなく、置かれた箱の幅**(`@container`)。

## 3. 書かないもの(古い・打ち消しを強いる)

| 規則 id | 書かないこと | 代わりに |
|---|---|---|
| `no-important` | `!important` | 層と、低い詳細度 |
| `no-id-selector` | `#id { … }` | クラス |
| `no-global` | `:global(.x)` で別の部品を書き換える | カスタムプロパティを渡す |
| `selector-depth` | `.a .b .c`、`.a > .b + .c` | クラス一つ |
| `no-margin` | `margin-top: 1rem` など | 親の `gap` / `padding` |
| `logical-only` | `margin-left`・`left`・`text-align: left`・`border-top-left-radius` | `margin-inline-start`・`inset-inline-start`・`text-align: start`・`border-start-start-radius` |
| `no-float` | `float` / `clear` | `flex` / `grid` |
| `viewport-width-query` | `@media (max-width: 40rem)` | `@container (width < 40rem)`(範囲構文)。`@media` は、**利用者の設定**(`prefers-*`・`hover`・`pointer`・`forced-colors`・`print`)だけ |
| `no-vendor-prefix` | `-webkit-` など | 接頭辞なし(例外: `-webkit-line-clamp`、`mask` の移行) |
| `no-raw-color` | `#fff`・`rgb(…)` を部品に | `var(--color-…)` |
| `font-size-unit` | `font-size: 14px` | `rem`・`clamp()` |
| `no-numeric-z-index` | `z-index: 40` | `var(--layer-…)` |
| `inline-style-props` | `style="margin-top: …"` | クラス、またはカスタムプロパティ |
| `no-click-on-div` | `<div onclick>` | `<button>` / `<a>` |
| `global-unlayered` | `src/styles/` の規則を `@layer` の外に | `@layer` の中 |

HTML は、**ネイティブの要素を先に**: `<button>`・`<a>`・`<dialog>`・`popover`・`<details>`・
フォームの部品。ARIA は、ネイティブで言えないときだけ。`<br>` や `<table>` で配置しない。

## 4. 新機能の受け入れ

**基準は Baseline**(web-features のデータ、2026-10-18 に取得)。

- **「広く使える」(high)と「最近使える」(low)は、すぐ使ってよい。** 待たない。
- **まだ足りない(limited)ものは**、`@supports` で囲み、**無くても使える**既定を残す。
  使うたびに、この表に足す。
- 四半期に一度、この表を取り直す: `node web/scripts/baseline-status.mjs`(web-features のデータを取って、状態を出す)。

| 機能 | 状態 | 日付 | 使い道 |
|---|---|---|---|
| `@layer`(カスケードレイヤー) | high | 2022-03 | §1-a の要 |
| `:where()` / `:is()` | high | 2021-01 | 詳細度 0 の規則 |
| `@container`(コンテナクエリ) | high | 2023-02 | 幅の判断 |
| CSS nesting | high | 2023-12 | 部品の中の書き方 |
| `:has()` | high | 2023-12 | 親を状態で変える |
| `subgrid` | high | 2023-09 | 列を、親の格子に揃える |
| `color-mix()` / `oklab` / `lab` | high | 2023-05 | 色の組み立て |
| 論理プロパティ | high | 2021-09 | §3 の `logical-only` |
| メディアクエリの範囲構文 | high | 2023-03 | `width < 40rem` |
| `light-dark()` | low | 2024-05 | 明暗 |
| `@property`(登録カスタムプロパティ) | low | 2024-07 | 型のある環境の値 |
| `popover` | low | 2025-01 | 重ね表示(メニュー) |
| `text-wrap: balance` | low | 2024-05 | 見出し |
| `@starting-style` | low | 2024-08 | 出現の動き |
| 相対色(relative color) | low | 2024-09 | 色の派生 |
| `content-visibility` | low | 2025-09 | 長いリスト |
| View Transitions(同一文書) | low | 2025-10 | 画面の移り |
| `@scope` | low | 2026-03 | 部品の中だけに効かせる(egui の `scope`) |
| `field-sizing` | low | 2026-06 | 入力欄の自動の高さ |
| コンテナのスタイルクエリ | low | 2026-05 | 環境の値で分岐 |
| `contrast-color()` | low | 2026-04 | 読める文字色 |
| `sibling-count()` | low | 2026-08 | 数に応じた配置 |
| anchor positioning | **limited** | — | `@supports` で囲む(未到達) |
| `text-wrap: pretty` | **limited** | — | 効けば得、無くても困らない |
| `line-clamp`(接頭辞なし) | **limited** | — | `-webkit-line-clamp` を例外で許す |

## 5. 今の状態と、進め方

検査は **ratchet**(`css-subset.baseline.json`)。いま有る違反は記録し、**新しい違反が
増えると失敗する**。減ったぶんは `--update` で記録に反映する。

- いまの違反(`pnpm run css-check -- --report`): 合計 501。多いもの: `logical-only` 123、
  `inline-style-props` 110、`global-unlayered` 110(`src/styles/` の規則の数)、`no-margin` 77。
- **`src/styles/` を `@layer` に入れるのは、見た目に効く**(いま、全体の CSS が、
  部品の scoped な規則より詳細度で勝つ所が有る)。層を入れる前後で、`pnpm run shots` と
  `ux-check` で見比べて、一つずつ進める。
- 部品の `margin` は、親の `gap` に置き換えていく。投稿カードなど、触る部品から。

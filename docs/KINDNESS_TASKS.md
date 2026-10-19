# 親切の直し — 並列で進めるためのタスク表

`KINDNESS_AUDIT.md` の「次の一手」を、ぶつからない単位に分けた表。
一つのタスクは一つのスレッド(一つのブランチ、一つの PR)で進められる。

## 並列の決まり

- **触るファイルが重ならないものは、同時に進めてよい。** 重なるものは、表の「順」の通りに。
- **`web/src/lib/locales/ja.ts` と `ko.ts` は、みんなが触る。** 文面を足すときは、
  既存の行を書き換えず、自分のタスクの見出しコメントの下に、キーを足すだけにする。
  そうすれば、マージのぶつかりが起きても、両方残すだけで直る。
- **`StatusActions.svelte` を触るタスクは、一度に一つだけ**(T4・T5・T6)。
- どのタスクも、`CODE_STYLE.md` §7 のチェックリストを通してから終える。
  web を触ったら `cd web && pnpm run check`。

## 表

| 順 | # | タスク | 触るファイル | 先に要るもの | 約束 |
|---|---|---|---|---|---|
| A(今すぐ、並列) | T1 | 失敗の文面に「なぜ」と次の一手を足す | `web/src/lib/locales/ja.ts`、`ko.ts`、`web/src/lib/components/Composer.svelte`(`handleErr` のみ) | なし | 3 |
| A | T2a | フィードバックの受け箱(サーバ側。運営だけが読める。決定済み) | `api/` と `elixir/` の新規ファイル、migration。`docs/ARCHITECTURE.md` を先に読む | なし | 聞く |
| A | T2b | フィードバックの口(隅の小さなリンク。画面名・言語・版だけ自動で添える) | 新規 `web/src/lib/components/Feedback.svelte`、`web/src/routes/+layout.svelte`(一行)、`ja.ts`/`ko.ts`(足すだけ) | T2a の口の形(エンドポイントと本文の型)。先に型だけ決めれば並列にできる | 聞く |
| A | T3 | メールのお願いに、長く黙る選択を足す | `web/src/lib/components/EmailNudge.svelte`、`ja.ts`/`ko.ts`(足すだけ) | なし | 7 |
| A | T0 | 調べるだけ: 投稿の編集の導線はあるか、投稿の「…」からミュート・ブロックできるか | 読むだけ(書かない) | なし | 2・6 |
| B(T0 のあと) | T4 | 「数を隠す」設定(お気に入り・ブースト・フォロワー) | `StatusActions.svelte`、`web/src/routes/@[acct]/+page.svelte`、`web/src/routes/settings/+page.svelte`、`web/src/lib/ux/`(新規一ファイル) | なし | 8 |
| B(T4 のあと) | T5 | 投稿の編集の導線(T0 で「無い」と分かったときだけ) | `StatusActions.svelte`、`Composer.svelte`、API 側 | T0 | 6 |
| B(T5 のあと) | T6 | 投稿のメニューから、ミュート・ブロックに一手で届く(T0 で足りないと分かったときだけ) | `StatusActions.svelte` | T0 | 2 |
| C(B のあと) | T7 | 削除に数秒の「元に戻す」(連合への Delete を保留する。決定済み) | `Status.svelte`、`StatusActions.svelte`、delivery/API 側 | `StatusActions.svelte` の順(T4〜T6)が済むこと | 6 |

## 決めたこと

1. **T2 の送り先は、サーバ側の受け箱。** 運営だけが読める。UI は T2b。
2. **T7 は、連合への Delete を保留する。** 連合の反映はもともと遅いので、数秒の猶予は
   相手側から見て自然。猶予の間に取り消したら、Delete を出さずに終える。
   猶予を過ぎたら、いまの削除と同じ。(ひなたさんの判断)

## 順の理由

- A の四つ(T1・T2a・T2b・T3)は、触るファイルが重ならない。ロケールだけ、足すだけの決まりで安全。
- T0 は読むだけなので、A と同時にできる。T4〜T6 は T0 の結果で、要るかどうかが決まる。
- T4・T5・T6 は、どれも `StatusActions.svelte` を触る。同時に進めると、ぶつかる。
- T7 は、`StatusActions.svelte` の順が済んでから。保留の長さ(数秒)は、実装の最初に決める。

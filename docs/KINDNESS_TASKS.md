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
| A | T2 | フィードバックの口(隅の小さなリンク。画面名・言語・版だけ自動で添える) | 新規 `web/src/lib/components/Feedback.svelte`、`web/src/routes/+layout.svelte`(一行)、`ja.ts`/`ko.ts`(足すだけ) | 送り先を決める(下の「決めること」) | 聞く |
| A | T3 | メールのお願いに、長く黙る選択を足す | `web/src/lib/components/EmailNudge.svelte`、`ja.ts`/`ko.ts`(足すだけ) | なし | 7 |
| A | T0 | 調べるだけ: 投稿の編集の導線はあるか、投稿の「…」からミュート・ブロックできるか | 読むだけ(書かない) | なし | 2・6 |
| B(T0 のあと) | T4 | 「数を隠す」設定(お気に入り・ブースト・フォロワー) | `StatusActions.svelte`、`web/src/routes/@[acct]/+page.svelte`、`web/src/routes/settings/+page.svelte`、`web/src/lib/ux/`(新規一ファイル) | なし | 8 |
| B(T4 のあと) | T5 | 投稿の編集の導線(T0 で「無い」と分かったときだけ) | `StatusActions.svelte`、`Composer.svelte`、API 側 | T0 | 6 |
| B(T5 のあと) | T6 | 投稿のメニューから、ミュート・ブロックに一手で届く(T0 で足りないと分かったときだけ) | `StatusActions.svelte` | T0 | 2 |
| C(設計が先) | T7 | 削除に数秒の「元に戻す」 | `Status.svelte`、`StatusActions.svelte`、delivery/API 側 | 連合への Delete を遅らせる設計の決定 | 6 |

## 決めること(スレッドを始める前に、ひなたさんに)

1. **T2 の送り先。** サーバ側の受け箱(運営だけが読める)に溜めるのか、既存の連絡先に送るのか。
   どちらでも、UI は同じ。
2. **T7 の設計。** 「元に戻す」の間、連合への Delete を保留するか、まず自分の画面だけ隠すか。
   連合に流れた Delete は、取り戻せない。

## 順の理由

- A の三つ(T1・T2・T3)は、触るファイルが重ならない。ロケールだけ、足すだけの決まりで安全。
- T0 は読むだけなので、A と同時にできる。T4〜T6 は T0 の結果で、要るかどうかが決まる。
- T4・T5・T6 は、どれも `StatusActions.svelte` を触る。同時に進めると、ぶつかる。
- T7 は、削除の意味そのものが変わるので、設計の決定を待つ。

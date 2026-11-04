<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 資料の目次

> **意図:** ここにある資料が、「だれの、どんな迷いのためのものか」で並んでいるように。
> **読み手の問題(仮説):** 「自分が読むべきなのは、どれ?」
>
> 並びは、**sukhi のこと → 使う → 立てる → つくる**。技術の資料は、いちばん後ろです。
> 一つの頁は、一つの問いに答えます。迷ったら、一番上の行から。

## 1. sukhi は、どんな場所か

| 知りたいこと | 資料 |
| --- | --- |
| ひとことで | [`../README.md`](../README.md) |
| 画面が、相手に負っているもの(九つの約束) | [`KINDNESS.md`](KINDNESS.md) |
| お金も物もいらない七つの施しで、見えるところを考えなおす | [`MUZAI_NO_SHICHISE.md`](MUZAI_NO_SHICHISE.md) |

## 2. 使う

| 知りたいこと | 資料 |
| --- | --- |
| 入りかた、書きかた、通知、引っ越し、やめるとき | [`USING.md`](USING.md) |
| Mastodon 用のアプリから使うとき、何ができるか | [`MASTODON_API.md`](MASTODON_API.md) |
| 意見を送ると、どうなるか(運営の側) | [`FEEDBACK.md`](FEEDBACK.md) |

## 3. 立てる(自分のサーバー)

はじめに [`OPERATIONS.md`](OPERATIONS.md)。準備 → 最初の起動 → 日々の手入れ、の順です。

| 知りたいこと | 資料 |
| --- | --- |
| 全体の入口と、責任のわけかた | [`OPERATIONS.md`](OPERATIONS.md) |
| 預かりものを、こわがらずに守る | [`CARING_FOR_YOUR_SERVER.md`](CARING_FOR_YOUR_SERVER.md) |
| ① 箱の準備 | [`OPS_PREPARE.md`](OPS_PREPARE.md) |
| ② 最初の起動、更新、戻し | [`OPS_DEPLOY.md`](OPS_DEPLOY.md) |
| ③ 控え・更新・見守り・困ったとき | [`OPS_MAINTAIN.md`](OPS_MAINTAIN.md) |
| SSH のはじめかた | [`OPERATING_OVER_SSH.md`](OPERATING_OVER_SSH.md) |
| Docker / Podman の選び方と導入 | [`RUNTIME.md`](RUNTIME.md) |
| Quadlet の箱で image を入れ替える | [`OPS_UPDATE_QUADLET.md`](OPS_UPDATE_QUADLET.md) |
| Tailscale で管理の道をひとまとめに | [`TAILSCALE.md`](TAILSCALE.md) |
| 環境変数(全部) | [`ENV.md`](ENV.md) |
| Datalevin の置き場所と設定 | [`DATALEVIN.md`](DATALEVIN.md) |
| 配信キューを SQLite に移す | [`DELIVERY_QUEUE_MIGRATION.md`](DELIVERY_QUEUE_MIGRATION.md) |
| bot よけ(Anubis) | [`anubis.md`](anubis.md) |
| CSS や画面の小さな修正を、焼かずに差し替える | [`static-override.md`](static-override.md) |
| 間違って入ったデータを直す | [`data-correction.md`](data-correction.md) |
| バックアップ | [`../infra/backup/README.md`](../infra/backup/README.md) |
| OCI に立てる(Terraform) | [`../infra/terraform-x64-freetier/README.md`](../infra/terraform-x64-freetier/README.md) |

## 4. つくる(コードを読む・直す人へ)

はじめに [`DEVELOPING.md`](DEVELOPING.md)、次に [`ARCHITECTURE.md`](ARCHITECTURE.md)。

| 知りたいこと | 資料 |
| --- | --- |
| 手元で動かす・テストする・学んだ相手 | [`DEVELOPING.md`](DEVELOPING.md) |
| 全体のかたち(正本、英語) / 日本語版 | [`ARCHITECTURE.md`](ARCHITECTURE.md) / [`ARCHITECTURE.ja.md`](ARCHITECTURE.ja.md) |
| 安全と速さを、構造で守る書きかた | [`CODE_STYLE.md`](CODE_STYLE.md) |
| アドオンの約束ごと | [`ADDONS.md`](ADDONS.md) |
| テストの走らせかた | [`TESTING.md`](TESTING.md) |
| 外に開いている口の一覧 | [`web-surface.md`](web-surface.md) |
| 押す・キー・戻る、の動き(OS ごと) | [`UX_CONTRACT.md`](UX_CONTRACT.md) |
| 使う HTML / CSS を絞る | [`CSS_SUBSET.md`](CSS_SUBSET.md) |
| Datalevin のデータ構造 | [`DATALEVIN_SCHEMA.md`](DATALEVIN_SCHEMA.md) |
| Web Push の設計と、実際にできたもの | [`WEBPUSH.md`](WEBPUSH.md) |
| バックエンドを、ゆったりさせる | [`UNHURRIED_BACKEND.md`](UNHURRIED_BACKEND.md) |
| ネイティブ実装を差し込む四つの継ぎ目 | [`native-seams.md`](native-seams.md) |
| 画面(web-next) | [`../web-next/README.md`](../web-next/README.md) |
| 負荷・異常の見張り(Julia) | [`METRICS_REPORT.md`](METRICS_REPORT.md)、[`../analysis/README.md`](../analysis/README.md) |
| 古い道具: 退役した Bun/Fedify の worker | [`FEDIFY.md`](FEDIFY.md)、[`../bun/README.md`](../bun/README.md) |
| 古い道具: SvelteKit の `web/`(維持のみ) | [`../web/README.md`](../web/README.md) |

## 5. 連合の約束と仕様

| 知りたいこと | 資料 |
| --- | --- |
| このサーバーが ActivityPub をどう話すか | [`FEDERATION.md`](FEDERATION.md) |
| 実装している仕様の一覧と、sukhi が書いた仕様 | [`specs/README.md`](specs/README.md)([日本語](specs/README.ja.md)) |
| Misskey と出会うとき、何をしているか | [`misskey-interop-sukhi.md`](misskey-interop-sukhi.md) |
| Pull Federation(sukhi 独自のプロトコル) | [`PULL_FEDERATION.md`](PULL_FEDERATION.md) |
| 実装している仕様を宣言する案 | [`spec-declaration-notes.md`](spec-declaration-notes.md) |

## 6. これから(案・設計のみ。実装はまだ)

| 案 | 資料 |
| --- | --- |
| sukhi.social の中の、小さな独立コミュニティ | [`COMMUNITY_SUPPORT.md`](COMMUNITY_SUPPORT.md) |
| サーバーシェル `sukhi` | [`SERVER_SHELL.md`](SERVER_SHELL.md) |
| 連合の受け入れを reducer で書く | [`FEDERATION_REDUCER.md`](FEDERATION_REDUCER.md) |
| フォロー分を、まとめて pull する | [`PULL_FEDERATION_BULK.md`](PULL_FEDERATION_BULK.md) |
| Misskey の API | [`MISSKEY_API.md`](MISSKEY_API.md) |
| まだ手をつけていないこと / 決め待ちのこと | [`../TODO.md`](../TODO.md) / [`../OPEN_QUESTIONS.md`](../OPEN_QUESTIONS.md) |

## 書くときの約束

新しい資料を足すときは、頁の先頭に、先に二行だけ書いてください。
**意図**(なんのために、だれに、どんな気持ちで帰ってほしいか)と、**読み手の問題**(その人は、いま何に迷っているか)。
技術は、そのあと。聞いていない問題は「仮説」と書きます。

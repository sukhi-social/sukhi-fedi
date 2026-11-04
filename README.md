<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi

急がなくていい場所で、ことばを置いて、ときどき顔を出す。
sukhi は、そのための、連合型(ActivityPub)の SNS サーバーです。
[sukhi.social](https://sukhi.social) は、このソフトウェアで動いています。

*English, briefly:* sukhi is a federated (ActivityPub) social server built to be calm:
posts wait a few minutes before they go out, reactions arrive in small batches, nothing
shows counts or unread badges. It speaks the Mastodon client API and federates with
Mastodon, Misskey and others. The rest of this page is in Japanese; the technical
documents under [`docs/`](docs/README.md) are mostly English.

## 1. どんな場所か

長くいても、ちょっと顔を出すだけでも、どちらも「ふつう」にしたい。
そのために、画面のほうが、いくつかのことを先に引き受けています。

- **投稿は、すぐには出ません。** 書いてから約四半刻(15分)、「お預かり」になります。
  そのあいだは、読み返して、直して、やめることができます。
- **反応は、ポツポツと届きます。** お気に入りやブーストの通知は、少し置いて、
  まとめて出します。返信とフォロー申請だけは、すぐ。
- **数を出しません。** お気に入り・ブースト・フォロワーの数も、通知の未読の数やバッジも。
  競わなくていいように。
- **時間は、うつろいで言います。** 「今日の昼下がり」「昨日の宵」。分や秒は言いません。
- **列には、終わりがあります。** 最後には「ここまで、です。」と出ます。
  読み終えたと思っていい場所があります。

こう決めていることも、あります(画面は、まだ追いついていないところがあります)。

- **静かにする道を、同じ大きさで置く。** 見たくないものを遠ざけるのは、
  ブロックや通報と同じくらい、見つけやすいところに。
- **入るのと同じくらい、出るのも易しく。** 理由は聞かない。引き止めない。

どれも技術的には、できることを**わざと控えた**ものです。
控えたぶんの余裕は、サーバーを軽く、長持ちさせるほうに使っています。
考え方は [`docs/KINDNESS.md`](docs/KINDNESS.md)(画面が相手に負っているもの)にあります。

つながる先は、Mastodon や Misskey など、ActivityPub を話す世界です。
Mastodon 用のアプリ(Elk、Phanpy、Ivory、Tusky など)からも使えます。
画面は日本語・한국어・English。ホーム画面に追加すれば、アプリのようにも開けます。

## 2. 使いはじめる

- ようすを見るには、[about.sukhi.social](https://about.sukhi.social) から。
- 入りかた、書きかた、通知のこと、引っ越し、やめたくなったとき ──
  [`docs/USING.md`](docs/USING.md) に、順に書きました。
- うまくいかないこと、あったらいいなと思うことは、アプリの「意見を送る」から。
  返事はできないことがありますが、ちゃんと読みます。

## 3. 自分のサーバーを立てる

sukhi は、だれでも自分の場所に立てられます。ただ、サーバーは**預かりもの**でもあります。
急がなくて大丈夫です。手が回らなそうなときは、立てない道もあります
(sukhi.social の中に小さなコミュニティを置く案を、考えています)。

- 立てるときの入口は [`docs/OPERATIONS.md`](docs/OPERATIONS.md)。
  準備 → 最初の起動 → 日々の手入れ、の順に読めます。
- 守りかたを、こわがらせずに書いたものが [`docs/CARING_FOR_YOUR_SERVER.md`](docs/CARING_FOR_YOUR_SERVER.md)。
- まず手元で動かしてみたいだけなら、[`docs/DEVELOPING.md`](docs/DEVELOPING.md) の「手元で動かす」へ。
  `make dev` ひとつで、Docker なしで立ちます。

## 4. つくる人へ

設計・仕様・環境変数・テストなど、技術の資料は [`docs/README.md`](docs/README.md) に目次があります。
読む順番は、迷ったらこの三つから。

1. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) ── 全体のかたち(正本)
2. [`docs/CODE_STYLE.md`](docs/CODE_STYLE.md) ── 安全と速さを、構造で守る書きかた
3. [`docs/DEVELOPING.md`](docs/DEVELOPING.md) ── 動かす・テストする・学んだ相手

## 続けていくために

sukhi は、ひとりの手と、いただく応援で続いています。
くわしいことと、何に使っているかは、サーバーの `/support` に書いてあります。
応援してもしなくても、ここでできることは同じです。

## ライセンス

AGPL-3.0-or-later です([`LICENSE`](LICENSE))。
依存している [ojak-ex](https://github.com/sukhi-social/ojak-ex) は AGPL-3.0-only で、
使うときの注意は [`docs/DEVELOPING.md`](docs/DEVELOPING.md) に書いてあります。

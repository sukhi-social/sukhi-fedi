<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-fedi を運用する人へ(はじめに)

> 状態: **運用の手引きの入口。** サーバーの準備、デプロイ、メンテナンスを、順に書く。
> `sukhi` コマンド([`SERVER_SHELL.md`](SERVER_SHELL.md))はまだ実装がなく、手引きの中で「予定」と書いたものは、
> 実装されるまでは**いまの手順**(各章に併記)を使う。
> 書いてあることは、リポジトリの内容から読み取ったもの。**実機で通したものではない**(章ごとに「未確認」を示した)。

サーバーを持つことは、**預かりもの**を持つことでもあります。急がなくて大丈夫です。
まず、この順に読んでください。

```
① 準備          → OPS_PREPARE.md   箱を用意して、守りの土台を作る
② 最初のデプロイ → OPS_DEPLOY.md    動かして、確かめる
③ 日々の手入れ   → OPS_MAINTAIN.md  控え・更新・見守り・困ったとき
```

## 目次(すべての文書)

| 知りたいこと | 文書 |
| --- | --- |
| 箱の用意、SSH、玄関(nginx)、メール、置き場所 | [`OPS_PREPARE.md`](OPS_PREPARE.md) |
| 初回の起動、更新、戻し | [`OPS_DEPLOY.md`](OPS_DEPLOY.md) |
| 日課・週課・月課、控え(バックアップ)、見守り、困ったとき | [`OPS_MAINTAIN.md`](OPS_MAINTAIN.md) |
| SSH のはじめかた(鍵、tmux) | [`OPERATING_OVER_SSH.md`](OPERATING_OVER_SSH.md) |
| Docker / Podman / nerdctl の選び方と導入、nginx、CVE への備え | [`RUNTIME.md`](RUNTIME.md) |
| 弱くなりやすいところを、やさしく | [`CARING_FOR_YOUR_SERVER.md`](CARING_FOR_YOUR_SERVER.md) |
| 小さな独立コミュニティの見守り | [`COMMUNITY_SUPPORT.md`](COMMUNITY_SUPPORT.md) |
| `sukhi` コマンドと更新の設計 | [`SERVER_SHELL.md`](SERVER_SHELL.md) |
| 環境変数 | [`ENV.md`](ENV.md) |
| Datalevin の保存場所と設定 | [`DATALEVIN.md`](DATALEVIN.md) |
| データの訂正(間違って入ったものを直す) | [`data-correction.md`](data-correction.md) |
| 全体の作り | [`ARCHITECTURE.md`](ARCHITECTURE.md) |

## この手引きの前提(読み取れたこと)

- **主軸は Datalevin**(`SUKHI_STORE=datalevin`)で、`combined`(gateway・delivery・api を一つの BEAM に入れたもの)で動かす。
  Postgres 版は維持のみ。違いが出るところだけ、Postgres の場合を添える。
- 入口は **nginx(ホスト)→ Anubis → gateway** の形(RUNTIME.md §9)。
- 本番(OCI の箱)は、今は GitHub Actions が焼いた `sha-<commit>` の image を、haloy で入れ替えている。
  自前ホストは Compose(+ Podman か Docker)を想定する。

## 責任のわけかた

| | 誰が | 何を |
| --- | --- | --- |
| 箱と玄関 | あなた | OS の更新、SSH、nginx、証明書、ディスク |
| アプリ | あなた(更新は GitHub の main が焼いたものを入れる) | image の入れ替え、設定、控え |
| 預かっている人たち | あなた | 告知、問い合わせ、おいたへの対応 |
| 困ったとき | **みんな** | Matrix `#sukhi-social:matrix.org`、メール(宛先は未入力) |

一人で抱えなくて大丈夫です。わからないときは、止まって聞いてください。

## 自分で持つか、迎えてもらうか

手が回らなそうなときは、sukhi.social の中に小さな独立コミュニティを作る道があります
([`CARING_FOR_YOUR_SERVER.md`](CARING_FOR_YOUR_SERVER.md) の冒頭)。どちらも、同じ家の仲間です。

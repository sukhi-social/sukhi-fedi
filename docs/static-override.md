# 静的ファイルの即時差し替え

CSS や SPA の小さな修正のたびに release を焼くのは辛いので、host 由来の
override dir を一枚かぶせている。仕組みは単純:

```
deployex container（アプリの走る場所）
  ├── <release>/lib/sukhi_fedi-<vsn>/priv/static/   ← baked: release に焼かれたもの
  └── /app/priv/static-override/                    ← pushed: /var/lib/sukhi-fedi/static の read-only bind
```

baked path は `:code.priv_dir/1` が release version 込みで返すので、
override は version に依らない固定パスにしてある(`STATIC_OVERRIDE_DIR`
で変えられる。baked 側も `STATIC_BAKED_DIR` で ─ テスト用)。

## 差し替える

```sh
export DEPLOY_HOST=<箱>

make push-static     # SPA まるごと(npm run build → rsync)
make push-styles     # server-rendered ページ用の生 CSS だけ
make clear-static    # push を剥がして release のものに戻す
make static-status   # いまどちらが答えているか
```

BEAM の reload は要らない。ファイルを置いた次のリクエストから変わる。

## どちらが答えるか ── ビルドの日付で決まる

`npm run build` が `.static-build.json` を吐く(`web/scripts/static-manifest.mjs`)。

```json
{ "built_at": 1756032000, "built_at_iso": "...", "source": "push" }
```

これは **build/ の中身と一緒に旅をする** ── image に COPY されても、
release の tarball に入っても、rsync で箱に渡っても、ついてくる。
サーバはこの `built_at` を比べて、**新しく焼かれたほうの木**を使う。
比較は木ごと(ファイルごとではなく)なので、index.html とそれが名指す
chunk が別のビルドから混ざることがない。

だから既定では、`make release` は `make push-static` を上書きする。
それが正しい ── release のほうが新しく焼かれているので。

`x-static-source` ヘッダにどちらを返したかが出る:

```sh
curl -sI https://sukhi.f3liz.casa/static/index.html | grep x-static-source
#=> x-static-source: baked
```

### 押し切りたいとき

deployex accessory の env で:

| `STATIC_OVERRIDE` | 動き |
|---|---|
| `auto`（既定） | 新しく焼かれたほうが勝つ |
| `prefer` | push があれば、日付に関わらず push が勝つ |
| `only` | push しか見ない。無ければ 404(baked へ落ちない) |

`STATIC_OVERRIDE_ONLY=true` は `only` と同じ(natadeco がこれ)。

### ビルドが作らないもの

`styles/` と `emojis/` はどの SPA ビルドの出力でもない ── 前者は手で、
後者は絵文字インポータが置く。ビルドの日付が語れる対象ではないので、
**どのモードでも override 側が優先される**。変えるなら
`STATIC_OVERRIDE_ALWAYS`(カンマ区切りの prefix)。

### なぜ mtime をやめたか

もともとは override 先勝ちだった。古い `push-static` の残骸が新しい
deploy を覆い隠す事故があって、mtime が新しいほうを選ぶようにした。

ところが DeployEx は deploy のたびに release の tarball を展開する。
展開されたファイルの mtime は必ず「いま」になるので、**baked が永久に
勝ち、push が二度と効かなくなった**。2026-08-24 に気づくまで、10 日ぶん
効いていなかった ── しかも外から確かめる方法が無かったので、気づき
ようがなかった。

mtime は「どちらが新しいか」を答えているように見えて、実際には
「どちらが最近ファイルシステムに書かれたか」しか答えない。知りたかった
のは別のことだった。だからビルド自身に言わせて、`x-static-source` で
外から見えるようにした。

## ホスト側の初回セットアップ

`make push-static` が自動でやるが、手作業なら:

```sh
ssh rocky@host 'sudo mkdir -p /var/lib/sukhi-fedi/static && sudo chown rocky /var/lib/sukhi-fedi/static'
```

deploy.yml の `accessories.deployex.volumes` がこの host path を bind
している。

## いつ使わないか

- `.ex` を触ったら、これでは反映されない ─ `make release`
- migration を足したら同じく `make release`
- `botPolicies.yaml` / `imprint.md` は anubis image に焼かれているので、
  Anubis 側で同じ override 機構を作るか image rebuild

## 安全のために

- override mount は `:ro` ─ コンテナ内のバグで上書きされない
- path-traversal guard は override 側にも効く ─ `..` は弾く

## 抜け穴(やらかしやすい二つ)

### 1. SPA の CSS は `/static/styles/` 経由では更新できない

SPA は Vite が CSS を bundle して `_app/immutable/assets/<hash>.css`
を吐く。`+layout.svelte` の `import '../styles/app.css'` はビルド時に
そっちへ食われる。だから `web/src/styles/app.css` を `push-styles`
で投げても、SPA のページ(timeline / signup / check)には反映されない。

`/static/styles/app.css` を読むのは **server-rendered な /login と
/oauth/authorize の consent 画面だけ**。SPA 側のスタイルを直したい
ときは `make push-static`。

### 2. `rsync --delete` が `styles/` を吹き飛ばす

`web/build/` の出力に `styles/` は含まれない(あれは別管理)。
だから素朴に `rsync -av --delete web/build/ host:STATIC_DIR/` を
やると、host 側の `styles/` まで削られて /login が裸 HTML になる。
`emojis/` も同じ。

`push-static` は `--exclude=styles --exclude=emojis` を付けてこれを
避けている。手で rsync するときも同じ exclude を忘れない。

# gateway が配る静的ファイル

gateway が自分で `/static/` の下から出すのは、頁ではない二種類だけです。
頁・アイコン・web manifest は、web の前線(web-next など)のものです。

```
app container（アプリの走る場所）
  ├── <release>/lib/sukhi_fedi-<vsn>/priv/static/   ← baked: release に焼かれたもの
  └── /app/priv/static-override/                    ← pushed: /var/lib/sukhi-fedi/static の read-only bind
```

| path | どちらの木が答えるか | 中身 |
|---|---|---|
| `/static/emojis/…` | override dir | 絵文字インポータが host に置いたカスタム絵文字 |
| それ以外 | baked | `avatar-default.svg` ── 画像の無いアカウントを API が名指すシルエット。他のサーバーのクライアントが取りに来る |

どちらの木が答えるかは、path だけで決まります。二つは互いに落ちあいません:
絵文字が override dir に無ければ 404 で、release が同じ名前を持っていても
見ません。

baked path は `:code.priv_dir/1` が release version 込みで返すので、
override は version に依らない固定パスにしてあります(`STATIC_OVERRIDE_DIR`
で変えられる。baked 側も `STATIC_BAKED_DIR` で ─ テスト用)。実装は
`SukhiFedi.Web.StaticFiles`。

## 絵文字を置く

BEAM の reload は要りません。ファイルを置いた次のリクエストから変わります。

host 側の初回:

```sh
ssh rocky@host 'sudo mkdir -p /var/lib/sukhi-fedi/static/emojis && sudo chown rocky /var/lib/sukhi-fedi/static'
```

`haloy.yaml` の volumes(`/var/lib/sukhi-fedi/static:/app/priv/static-override:ro`)
がこの host path を bind しています。置くとき:

```sh
rsync -av --chmod=D755,F644 emojis/ rocky@host:/var/lib/sukhi-fedi/static/emojis/
```

## ファイルの mode に気をつける

**アプリは root ではない uid(10002)で動いています。** 置くファイルは
*others から読める* 必要があります。読めないファイルがあると、`stat` は通る
(ディレクトリの実行権だけで足りる)ので、**200 のヘッダを送ってから本体が
eacces で落ちる** ── クライアントには 502、ログには 200 が並びます。

だから、アプリは *読めるかどうか* を見て選びます(`File.stat` の `:access`)。
読めないファイルは最初から候補にならず、404 になります。それでも、置く側の
rsync には `--chmod=D755,F644` を付けてください。手で置いたときは:

```sh
ssh rocky@host 'sudo chmod -R a+rX /var/lib/sukhi-fedi/static'
```

## いつ使わないか

- `.ex` を触ったら、これでは反映されない ─ image を焼いて `haloy deploy`
  (`bin/build-on-box.sh combined` → `haloy deploy -t sukhi-fedi-app`)
- migration を足したら同じく image を焼き直す
- `botPolicies.yaml` / `imprint.md` は anubis image に焼かれているので、
  Anubis 側の image rebuild
- 頁の見た目(CSS・JS・アイコン)は、ここでは変えられない ── web の前線
  (web-next なら `web-next/public/`)の image を焼く

## 安全のために

- override mount は `:ro` ─ コンテナ内のバグで上書きされない
- path-traversal guard は両方の木に効く ─ `..` は弾く

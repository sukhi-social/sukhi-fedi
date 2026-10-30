<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Quadlet の箱で image を入れ替える(skopeo)

> 状態: **案。実機では未確認。** 「未確認」と書いた箇所は、最初の一回を手で確かめながら進める。
> 正本の設計は [`RUNTIME.md`](RUNTIME.md) §12.3(Quadlet が主、image はダイジェストで固定)と
> [`SERVER_SHELL.md`](SERVER_SHELL.md) §5.1(`sukhi release`)。ここはその最小の手作業版で、
> `scripts/sukhi-swap-image.sh` が同じ手順を一本にしたもの(`sukhi release` の下地)。

## 0. 考え方

- タグ(`:v1`)は動く。**入れる前に、ダイジェストに解決して、以降はダイジェストだけを見る。**
- 取ってくるのは `skopeo copy`。デーモン不要で、何を取ったかが一つの値(ダイジェスト)で残る。
- Quadlet の `.container` 本体は触らず、**ドロップインの 1 ファイル**(`Image=` だけ)を書き換える。戻すときもそのファイルだけ。
- 起動が失敗したら、前の image に戻す。`AutoUpdate=` は使わない(署名の検証をしないため。RUNTIME.md §5.1)。

## 1. 公開されるタグ

`release.yml` が `v*.*.*` のタグで `sukhi-fedi-combined` を **amd64 + arm64 の multi-arch** で出す。

| タグ | 意味 |
| --- | --- |
| `0.4.14` / `0.4` | その版 / 回る patch |
| `v0` | 回る minor(**`v1` は `v1.0.0` を打つまで存在しない**) |
| `latest` | 最後に打ったタグ |
| `sha-xxxxxxx` | combined だけ。`combined-sha.yml` が main に付けるのと同じ名前 |

`v1` は `v1.0.0` のタグで初めて現れる(VERSION も 1.0.0)。`web-next` は release.yml の対象外で、`sha-` タグのみ(combined-sha.yml)。

## 2. 一回目の準備(未確認の箇所あり)

```sh
# 要るもの: podman 4.4 以降(ドロップインは 5.x でないと読まれないかもしれない。未確認)、skopeo、systemd --user
sudo dnf install -y skopeo          # Rocky: AppStream にあるはず(dnf info skopeo で確認)
loginctl enable-linger sukhi        # ログアウトしても --user のユニットが動く

# 今動いている image を記録する(これが最初の「前の版」になる)
mkdir -p ~/.local/state/sukhi-release/sukhi-gateway
podman inspect --format '{{.ImageName}}' systemd-sukhi-gateway   # コンテナ名は Name= による
```

公開 image が private なら、先に `skopeo login ghcr.io` (読み取りだけの token)。

## 3. 更新の手順

```sh
export SUKHI_IMAGE_REF=ghcr.io/<owner>/sukhi-fedi-combined:v0   # 追いかけるタグ
# ユニット名は .container ファイルの名前(sukhi-gateway.container → sukhi-gateway.service)。rootful なら SUKHI_SCOPE=system
# 先に確かめる: systemctl --user list-units --all 'sukhi*'
export SUKHI_HEALTH_URL=http://127.0.0.1:4000/                  # 確認用の口(あれば。ヘルスの URL は要確認)

scripts/sukhi-swap-image.sh plan     # 何に解決され、何を入れるか。変更はしない
scripts/sukhi-swap-image.sh apply    # 取得 → ドロップイン書き換え → 再起動 → 確認。失敗なら自動で戻す
scripts/sukhi-swap-image.sh rollback # 動いたあとで気づいたとき、一つ前へ
```

表示は、`SUKHI_LANG=ja`(または `LANG=ja_JP.UTF-8`)で日本語になる。文言は MS-DOS(J)の流儀に寄せた(一行で何が起きたかを言い、次にすることを添える。確認は `(Y/N)?`)。
端末から `apply` / `rollback` を呼ぶと、先に確認が出る。自動化では `--yes`。

手でやるなら(`apply` の中身):

```sh
digest=$(skopeo inspect --no-tags --format '{{.Digest}}' docker://$SUKHI_IMAGE_REF)   # 1. 解決
skopeo copy docker://ghcr.io/<owner>/sukhi-fedi-combined@$digest \
            containers-storage:localhost/sukhi-combined:d-${digest#sha256:}           # 2. 取得(ダイジェスト指定)
# 3. ~/.config/containers/systemd/sukhi-gateway.container.d/10-image.conf を
#    [Container]\nImage=localhost/sukhi-combined:d-… に書き換え
systemctl --user daemon-reload && systemctl --user restart sukhi-gateway             # 4. 再起動
systemctl --user is-active sukhi-gateway; journalctl --user -u sukhi-gateway -n 50   # 5. 確認
```

Anubis と web-next(`sukhi-fedi-web-next`、`sha-` タグを `--tag` に)も同じ形で、`SUKHI_UNIT` / `SUKHI_LOCAL_NAME` / `--tag` を替えて呼ぶ。
**gateway と Anubis など複数の image は、一つずつ。**「同じ sha でそろえる」(combined-sha.yml)ときは、sha タグを `--tag` に渡す。

## 4. 戻し方とその限界

- `apply` が失敗(`is-active` が保てない、または `SUKHI_HEALTH_URL` が通らない)したら、記録した前の image に自動で戻る。
- `rollback` は一つ前に戻る。もう一度呼ぶと、元に戻る。記録は `~/.local/state/sukhi-release/<unit>/` の `current` / `previous` / `history`。
- **データベースの変更を含む版は、image を戻しても戻らないことがある**(SERVER_SHELL.md §5.6)。Datalevin の控え(`dtlv copy`、OPS_MAINTAIN.md §3)を更新の前に取る。
- 古い image は残る(戻すため)。容量が気になったら `podman image prune` ではなく、`podman images` で `d-…` の古いタグを選んで消す。

## 5. 署名

`release.yml`(`v*` タグ)と `combined-sha.yml`(main)は、push した image を **cosign の keyless 署名**でダイジェストに対して署名する
(Sigstore。秘密の鍵はない。身元は GitHub Actions の OIDC)。`sukhi-swap-image.sh` は `apply` の前に次を確かめ、通らなければ何も変えない:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/sukhi-social/sukhi-fedi/\.github/workflows/(release\.yml@refs/tags/v.+|combined-sha\.yml@refs/heads/main)$' \
  ghcr.io/<owner>/sukhi-fedi-combined@sha256:…
```

- `cosign` が箱に要る(Rocky は EPEL か公式の rpm。`dnf info cosign` で確認)。
- 署名が入る前に焼かれた image は検証に通らない。入れるなら `SUKHI_VERIFY=0` を明示する。
- main 以外のブランチ(`refactor/web-batches` や手動実行)の `sha-` は、身元が `refs/heads/main` でないので通らない。
- 署名は透明性ログ(Rekor)に残る。検証はオンラインで行う(オフライン検証は未確認)。

## 6. 未確認

- `skopeo copy` の宛先 `containers-storage:` に、このタグ形式で rootless のまま書けること。
- Quadlet のドロップイン(`<unit>.container.d/*.conf`)が使う Podman の版で効くこと。効かなければ、`Image=` の行を `sed` で直す形に替える。
- Rocky の AppStream の skopeo の版と、`skopeo inspect --format` の `{{.Digest}}` が multi-arch の一覧のダイジェストを返すこと。
- 署名の工程が CI で実際に通ること(初回の v1.0.0 タグ / main への push で確かめる)と、検証の正規表現が実物の身元と合うこと。
- ヘルスの URL(gateway に確認用の口があるか)。
- amd64 の combined が実際に焼けること(arm64 は combined-sha.yml で通っている)。

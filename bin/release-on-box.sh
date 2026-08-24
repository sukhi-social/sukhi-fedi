#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 箱(OCI A1, arm64)で sukhi-fedi の release を焼いて、DeployEx が見ている
# dist ディレクトリに置く。bin/build-on-box.sh の後継 ── 焼くものが image
# ではなく **tarball 一個** になった。registry も docker login も image tag
# も要らない。
#
# 使い方:
#   bin/release-on-box.sh            # 焼いて置く（DeployEx が数秒で拾う）
#   bin/release-on-box.sh --sync     # ツリーを送るところまで（build しない）
#
# その後は何もしなくていい。DeployEx が current.json の version が変わった
# のを見て、tarball を展開し、pre_commands(migration)を走らせ、古い BEAM を
# 止めて新しいのを起動する。進みぐあいはダッシュボードで:
#   ssh -L 5001:127.0.0.1:5001 rocky@$DEPLOY_HOST   →   http://localhost:5001
#
# 公開 multi-arch image は今までどおり .github/workflows/release.yml が ghcr
# に出し続ける（compose で自前ホストする人のための道は変わらない）。
#
# committed なツリーだけ送る（未コミットの変更は乗らない）。
set -euo pipefail

BOX="rocky@${DEPLOY_HOST:?set DEPLOY_HOST to the box ip/hostname}"
SRC_DIR='$HOME/sukhi-build'           # 箱の中のビルド木（_build/deps が住む）
STAGE_DIR='$HOME/sukhi-stage'         # git archive をそのまま置く場所（比較用）
DIST_DIR=/var/lib/sukhi-fedi/releases
BUILDER=sukhi-fedi-builder:v0
APP=combined

SHA=$(git rev-parse --short HEAD)
VERSION="$(tr -d '[:space:]' < VERSION)+${SHA}"

sync_only=false
[ "${1:-}" = "--sync" ] && sync_only=true

# ── 1. committed なツリーを箱へ ─────────────────────────────────────────────
# 二段にする。手元 → 箱は素の転送(staging へ)、**中身の比較は箱の中で**。
#
# なぜ分けるか: git archive は全ファイルの mtime を commit 時刻にするので、
# 素朴に展開すると一文字直しただけで Mix が全部を「新しい」と見て再コンパイル
# する。だから中身で比べる `--checksum` が要る ── のだけれど、macOS が積んで
# いる rsync は openrsync(protocol 29 / MD4)で、`--checksum` が冪等にならない
# (内容も mode も同じファイルを毎回送り直してくる)のを実測した。箱の中なら
# 両端とも rsync 3.2.5 なので、そこで比べれば正しく効く。ついでに、手元の
# マシンに何が入っているかに結果が左右されなくなる。
#
# `_build` / `deps` / `node_modules` は箱に住み続ける（だから二回目が速い）
# ので --delete の対象から外す。SPA 側の `.svelte-kit` / `build` と、そこから
# 中身をもらう `elixir/priv/static` も同じ ── どれも gitignore されていて
# git archive に載らないので、素朴に --delete をかけると毎回まるごと消えて、
# SvelteKit が毎回ゼロから焼き直すことになる。
echo "→ ship committed tree (HEAD=$SHA, version=$VERSION)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git archive HEAD | tar -x -C "$TMP"

ssh "$BOX" "mkdir -p $STAGE_DIR $SRC_DIR"
rsync -a --delete "$TMP/" "$BOX:sukhi-stage/"

ssh "$BOX" "rsync -a --delete --checksum \
  --exclude='_build/' \
  --exclude='deps/' \
  --exclude='node_modules/' \
  --exclude='/web/.svelte-kit/' \
  --exclude='/web/build/' \
  --exclude='/elixir/priv/static/' \
  $STAGE_DIR/ $SRC_DIR/"

if $sync_only; then
  echo "✓ synced only (no build)"
  exit 0
fi

# ── 2. 箱で焼く ────────────────────────────────────────────────────────────
# builder container は --user で「箱の rocky」として走る。bind mount に
# 書かれるものが全部 rocky のものになるので、次の rsync が困らない。
# HOME と npm cache は書ける場所へ逃がす（$HOME は container の中では
# 存在しない uid の家になるので）。
echo "→ build release in $BUILDER"
ssh "$BOX" "docker run --rm \
  --user \$(id -u):\$(id -g) \
  -e HOME=/tmp \
  -e npm_config_cache=/tmp/npm \
  -e MIX_ENV=prod \
  -e SUKHI_RELEASE_VERSION='$VERSION' \
  -v \$HOME/sukhi-build:/repo \
  -w /repo \
  $BUILDER bash -euo pipefail -c '
    cd /repo/web
    npm install --no-audit --no-fund
    npm run build

    # SPA を gateway の priv/static へ（combined/Dockerfile と同じ場所）
    mkdir -p /repo/elixir/priv/static/styles
    cp -r /repo/web/build/. /repo/elixir/priv/static/
    cp /repo/web/src/styles/tokens.css \
       /repo/web/src/styles/base.css \
       /repo/web/src/styles/app.css \
       /repo/elixir/priv/static/styles/

    cd /repo/combined
    mix deps.get --only prod
    mix release --overwrite
  '"

# ── 3. dist に置いて、current.json を書き換える ────────────────────────────
# DeployEx は current.json の version 文字列が「いま動いているもの」と
# 違うかどうかだけを見る（hash は運ぶだけで比べない）。だから最後の一行が
# デプロイの引き金。tmp に書いてから mv ＝ 半分書けた JSON を読ませない。
TARBALL="$APP-$VERSION.tar.gz"
echo "→ publish $TARBALL"
ssh "$BOX" "set -euo pipefail
  sudo mkdir -p $DIST_DIR/dist/$APP $DIST_DIR/versions/$APP/prod
  sudo chown -R rocky:rocky $DIST_DIR
  cp \$HOME/sukhi-build/combined/_build/prod/$TARBALL $DIST_DIR/dist/$APP/

  # 古いのを 5 個だけ残す。展開済みの release は DeployEx 側にあるので、
  # ここの tarball を消しても動いているものには触らない。
  ls -t $DIST_DIR/dist/$APP/$APP-*.tar.gz | tail -n +6 | xargs -r rm -f

  cat > $DIST_DIR/versions/$APP/prod/current.json.tmp <<'JSON'
{
  \"version\": \"$VERSION\",
  \"hash\": \"$SHA\",
  \"pre_commands\": [\"eval SukhiFedi.Release.migrate_all\"]
}
JSON
  mv $DIST_DIR/versions/$APP/prod/current.json.tmp $DIST_DIR/versions/$APP/prod/current.json
"

echo "✓ $VERSION published — DeployEx picks it up within ~5s"
echo "  watch: ssh -L 5001:127.0.0.1:5001 $BOX  →  http://localhost:5001"

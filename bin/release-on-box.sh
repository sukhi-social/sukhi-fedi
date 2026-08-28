#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 箱(OCI A1, arm64)で sukhi-fedi の release を焼いて、DeployEx が見ている
# dist ディレクトリに置く。bin/build-on-box.sh の後継 ── 焼くものが image
# ではなく **tarball 一個** になった。registry も docker login も image tag
# も要らない。
#
# 使い方:
#   bin/release-on-box.sh                     # 焼いて置く（DeployEx が数秒で拾う）
#   bin/release-on-box.sh --sync              # ツリーを送るところまで（build しない）
#   INSTANCE=natadeco bin/release-on-box.sh   # natadeco.com のほうを焼く
#
# 一つの箱に sukhi-fedi が二つ住んでいる。焼くものは同じ combined release で、
# 違うのは「どのフロントを積むか」と「どこへ置くか」だけ ── だから分岐は
# 下の case 一箇所に集めてある。切り替えは env で、DEPLOY_HOST と同じ渡しかた。
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
BUILDER=sukhi-fedi-builder:v0         # toolchain だけ。二つのインスタンスで共用
APP=combined

INSTANCE="${INSTANCE:-sukhi}"
case "$INSTANCE" in
  sukhi)
    BUILD=sukhi-build                 # 箱の中のビルド木（_build/deps が住む）
    STAGE=sukhi-stage                 # git archive をそのまま置く場所（比較用）
    DIST_DIR=/var/lib/sukhi-fedi/releases
    SPA=web                           # 焼くフロント
    SPA_INSTALL='npm install --no-audit --no-fund'
    SPA_BUILD='npm run build'
    DASH_PORT=5001
    ;;
  natadeco)
    BUILD=natadeco-build
    STAGE=natadeco-stage
    DIST_DIR=/var/lib/natadeco/releases
    SPA=web-natadeco                  # bun とその lockfile のまま（Makefile と同じ）
    SPA_INSTALL='bun install'
    SPA_BUILD='bun run build'
    DASH_PORT=5002
    ;;
  *)
    echo "unknown INSTANCE=$INSTANCE (sukhi | natadeco)" >&2
    exit 1
    ;;
esac

# 箱の中で展開させたいので `$HOME` は literal のまま渡す。
SRC_DIR="\$HOME/$BUILD"
STAGE_DIR="\$HOME/$STAGE"

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
echo "→ ship committed tree to $INSTANCE (HEAD=$SHA, version=$VERSION)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git archive HEAD | tar -x -C "$TMP"

ssh "$BOX" "mkdir -p $STAGE_DIR $SRC_DIR"
rsync -a --delete "$TMP/" "$BOX:$STAGE/"

ssh "$BOX" "rsync -a --delete --checksum \
  --exclude='_build/' \
  --exclude='deps/' \
  --exclude='node_modules/' \
  --exclude='/$SPA/.svelte-kit/' \
  --exclude='/$SPA/build/' \
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
  -e SUKHI_STATIC_SOURCE=release \
  -v $SRC_DIR:/repo \
  -w /repo \
  $BUILDER bash -euo pipefail -c '
    cd /repo/$SPA
    $SPA_INSTALL
    $SPA_BUILD

    # SPA を gateway の priv/static へ（combined/Dockerfile と同じ場所）
    cp -r /repo/$SPA/build/. /repo/elixir/priv/static/

    # サーバが描くページ(/login など)が読む素の token CSS。build 出力には
    # 居ないので別に運ぶ。web-natadeco はこれを持たない ── あちらの CSS は
    # bundle の中で、いま箱の override にも styles/ は無い。
    if [ -d /repo/$SPA/src/styles ]; then
      mkdir -p /repo/elixir/priv/static/styles
      cp /repo/$SPA/src/styles/tokens.css \
         /repo/$SPA/src/styles/base.css \
         /repo/$SPA/src/styles/app.css \
         /repo/elixir/priv/static/styles/
    fi

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
  cp $SRC_DIR/combined/_build/prod/$TARBALL $DIST_DIR/dist/$APP/

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
echo "  watch: ssh -L $DASH_PORT:127.0.0.1:$DASH_PORT $BOX  →  http://localhost:$DASH_PORT"

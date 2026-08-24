#!/usr/bin/env bash
# 箱(OCI A1, 217.x)で sukhi-fedi の image を焼いて、箱の private registry
# (127.0.0.1:5000) に push する。techo/bin/build-on-box.sh と同じ型。
#
# kamal には build させない（kamal の remote builder は buildkit コンテナ内から
# 127.0.0.1:5000 に push できないため ── techo で確認済み）。committed なツリーを
# git archive で箱に送り、箱で docker build → loopback registry に push する。
#
# **アプリの版はもうここを通らない。** 2026-08-24 から、gateway/delivery/api は
# DeployEx の中の一つの release になって、版は tarball で運ばれる ──
# `make release`(bin/release-on-box.sh)。この script に残っているのは「めったに
# 変わらない土台」だけ。
#
# 使い方:
#   bin/build-on-box.sh                  # 既定: builder deployex を焼く
#   bin/build-on-box.sh anubis           # config/anubis を変えたとき
#   bin/build-on-box.sh nats-bootstrap   # infra/nats を変えたとき
# その後:
#   kamal accessory reboot deployex      # deployex を焼き直したとき
#   kamal deploy --skip-push --version=<いま動いている版>   # anubis のとき
#
# gateway / delivery / api の entry は消した(旧 accessory も同日に削除)。戻したく
# なったら sukhi-deploy 側の revert と一緒に、この case にも戻す ── image 自体は
# 箱の registry に残っている。combined は compose 自前ホスト用の image なので残す。
#
# 公開 multi-arch image は今までどおり .github/workflows/release.yml が ghcr に
# 出し続ける。これは「自分の箱に出す」専用 ── arm64 単一・loopback registry。
#
# committed なツリーだけ送る（未コミットの変更は乗らない）。
set -euo pipefail

BOX="rocky@${DEPLOY_HOST:?set DEPLOY_HOST to the box ip/hostname}"
REG=127.0.0.1:5000
REGUSER=sukhi                       # techo の registry container に相乗り、user は分ける
SHA=$(git rev-parse HEAD)
REGPASS=$(grep '^REGISTRY_PASSWORD=' .kamal/secrets | cut -d= -f2)
# 同じ箱に相乗りする別サービス用の image 名前空間。既定は今までどおり
# sukhi-fedi-*。Kamal は web role の image に `service=$PREFIX` ラベルを
# 要求するので(anti-misconfig guard)、ラベルも一緒に付け替える ── 相手の
# deploy.yml の `service:` と揃っていないと deploy 自体が弾かれる。
PREFIX="${IMAGE_PREFIX:-sukhi-fedi}"

# name → context / dockerfile。release.yml の matrix と同じ context/file。
build_one() {
  local name="$1" ctx file push=true
  case "$name" in
    # combined は compose で自前ホストする人が焼く image。箱では使わない
    # (箱は tarball 経由)が、手元で確かめたいときのために残してある。
    combined)       ctx="."               file="combined/Dockerfile"        ;;
    bun)            ctx="bun"             file="bun/Dockerfile"             ;;
    nats-bootstrap) ctx="infra/nats"      file="infra/nats/Dockerfile"      ;;
    anubis)         ctx="config/anubis"   file="config/anubis/Dockerfile"   ;;
    # DeployEx とその中で動くアプリの土台。年に数回しか変わらない ── アプリ
    # の版は image ではなく tarball で運ぶ(bin/release-on-box.sh)。
    deployex)       ctx="infra/deployex"  file="infra/deployex/Dockerfile"  ;;
    # builder は kamal が触らない(箱の docker run から直に使う)ので registry
    # に置かない。1GB 超を loopback registry に積む意味が無い。
    builder)        ctx="infra/builder"   file="infra/builder/Dockerfile"   push=false ;;
    *) echo "unknown image: $name" >&2; return 1 ;;
  esac
  local img="$REG/$PREFIX-$name"
  if ! $push; then
    img="$PREFIX-$name"
    echo "→ build $name  (context=$ctx file=$file, local only)"
    ssh "$BOX" "cd ~/sukhi-images && docker build -f '$file' -t '$img:v0' '$ctx'"
    return
  fi
  echo "→ build + push $name  (context=$ctx file=$file)"
  # 順番に焼く＝CPU を一度に食い尽くさない。:v0 は accessory が pin する rolling、
  # :$SHA は anubis の kamal deploy --skip-push が拾う immutable。
  ssh "$BOX" "cd ~/sukhi-images \
    && docker build --label service=$PREFIX -f '$file' -t '$img:v0' -t '$img:$SHA' '$ctx' \
    && docker push '$img:v0' \
    && docker push '$img:$SHA'"
}

if [ "$#" -eq 0 ]; then set -- builder deployex; fi

# image を焼くためのツリーは ~/sukhi-images。アプリの release を焼く
# ~/sukhi-build とは別にする ── あちらは _build/deps が住み続ける場所で、
# ここは毎回まるごと消して展開し直すから(bin/release-on-box.sh 参照)。
echo "→ ship committed tree (HEAD=$SHA) to box"
git archive HEAD | ssh "$BOX" 'rm -rf ~/sukhi-images && mkdir -p ~/sukhi-images && tar -x -C ~/sukhi-images'

echo "→ login registry on box"
echo "$REGPASS" | ssh "$BOX" "docker login $REG -u $REGUSER --password-stdin >/dev/null"

for name in "$@"; do build_one "$name"; done

echo "✓ pushed: $*  (next: kamal accessory reboot <name>)"

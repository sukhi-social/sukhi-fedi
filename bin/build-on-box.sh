#!/usr/bin/env bash
# 箱(OCI A1, 217.x)で sukhi-fedi の image を焼いて、箱の private registry
# (127.0.0.1:5000) に push する。techo/bin/build-on-box.sh と同じ型。
#
# kamal には build させない（kamal の remote builder は buildkit コンテナ内から
# 127.0.0.1:5000 に push できないため ── techo で確認済み）。committed なツリーを
# git archive で箱に送り、箱で docker build → loopback registry に push する。
#
# 使い方:
#   bin/build-on-box.sh                  # 既定: gateway delivery api bun を焼く
#   bin/build-on-box.sh gateway          # 一つだけ（CPU 競合を抑えたいとき）
#   bin/build-on-box.sh anubis           # config/anubis を変えたとき
#   bin/build-on-box.sh gateway delivery api bun nats-bootstrap anubis  # 全部
# その後:
#   kamal accessory reboot gateway       # 箱が :v0 を pull し直して再起動
#   kamal deploy --skip-push             # anubis(web role) を焼いたとき
#
# 公開 multi-arch image は今までどおり .github/workflows/release.yml が ghcr に
# 出し続ける。これは「自分の箱に出す」専用 ── arm64 単一・loopback registry。
#
# committed なツリーだけ送る（未コミットの変更は乗らない）。
set -euo pipefail

BOX=rocky@217.142.242.103
REG=127.0.0.1:5000
REGUSER=sukhi                       # techo の registry container に相乗り、user は分ける
SHA=$(git rev-parse HEAD)
REGPASS=$(grep '^REGISTRY_PASSWORD=' .kamal/secrets | cut -d= -f2)

# name → context / dockerfile。release.yml の matrix と同じ context/file。
build_one() {
  local name="$1" ctx file
  case "$name" in
    gateway)        ctx="."             file="elixir/Dockerfile"        ;;
    combined)       ctx="."             file="combined/Dockerfile"      ;;
    delivery)       ctx="delivery"      file="delivery/Dockerfile"      ;;
    api)            ctx="."             file="api/Dockerfile"           ;;
    bun)            ctx="bun"           file="bun/Dockerfile"           ;;
    nats-bootstrap) ctx="infra/nats"    file="infra/nats/Dockerfile"    ;;
    anubis)         ctx="config/anubis" file="config/anubis/Dockerfile" ;;
    *) echo "unknown image: $name" >&2; return 1 ;;
  esac
  local img="$REG/sukhi-fedi-$name"
  echo "→ build + push $name  (context=$ctx file=$file)"
  # 順番に焼く＝CPU を一度に食い尽くさない。:v0 は accessory が pin する rolling、
  # :$SHA は anubis の kamal deploy --skip-push が拾う immutable。
  ssh "$BOX" "cd ~/sukhi-build \
    && docker build --label service=sukhi-fedi -f '$file' -t '$img:v0' -t '$img:$SHA' '$ctx' \
    && docker push '$img:v0' \
    && docker push '$img:$SHA'"
}

if [ "$#" -eq 0 ]; then set -- gateway delivery api bun; fi

echo "→ ship committed tree (HEAD=$SHA) to box"
git archive HEAD | ssh "$BOX" 'rm -rf ~/sukhi-build && mkdir -p ~/sukhi-build && tar -x -C ~/sukhi-build'

echo "→ login registry on box"
echo "$REGPASS" | ssh "$BOX" "docker login $REG -u $REGUSER --password-stdin >/dev/null"

for name in "$@"; do build_one "$name"; done

echo "✓ pushed: $*  (next: kamal accessory reboot <name>)"

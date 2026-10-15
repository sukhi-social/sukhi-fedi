#!/usr/bin/env bash
# 箱(OCI A1, 217.x)で sukhi-fedi の image を焼いて、箱の private registry
# (127.0.0.1:5000) に push する。techo/bin/build-on-box.sh と同じ型。
#
# kamal には build させない（kamal の remote builder は buildkit コンテナ内から
# 127.0.0.1:5000 に push できないため ── techo で確認済み）。committed なツリーを
# git archive で箱に送り、箱で docker build → loopback registry に push する。
#
# 焼いたあとの deploy は haloy（sukhi-deploy/ の haloy.yaml）。sukhi も natadeco も
# 同じ型で、image はここで焼き、版は haloy が image で運ぶ:
#
# 使い方:
#   bin/build-on-box.sh combined         # sukhi の本体（IMAGE_PREFIX は既定 sukhi-fedi）
#   bin/build-on-box.sh anubis           # config/anubis を変えたとき
#   IMAGE_PREFIX=natadeco bin/build-on-box.sh combined   # natadeco の版上げ
# その後（トンネルを張ってから）:
#   cd ~/repos/sukhi-deploy && haloy deploy -t sukhi-fedi-app
#   cd ~/repos/sukhi-deploy/natadeco && haloy deploy -t natadeco
#
# gateway / delivery の entry は消した(旧 accessory も同日に削除)。戻したく
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
# 箱の registry のパスワードは環境変数で渡す(kamal の .kamal/secrets には頼らない)。
REGPASS="${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD to the box registry password}"
# 同じ箱に相乗りする別サービス用の image 名前空間。既定は今までどおり
# sukhi-fedi-*。Kamal は web role の image に `service=$PREFIX` ラベルを
# 要求するので(anti-misconfig guard)、ラベルも一緒に付け替える ── 相手の
# deploy.yml の `service:` と揃っていないと deploy 自体が弾かれる。
PREFIX="${IMAGE_PREFIX:-sukhi-fedi}"

# name → context / dockerfile。release.yml の matrix と同じ context/file。
build_one() {
  local name="$1" ctx file push=true
  case "$name" in
    # sukhi も natadeco も combined で動く(natadeco は `IMAGE_PREFIX=natadeco`)。
    # combined と api は compose で自前ホストする人の image でもある。sukhi の
    # gateway/delivery を消したときに api も落としてしまって、natadeco のビルド
    # 経路を一度壊した(2026-08-25 に気づいて戻した)。
    combined)       ctx="."               file="combined/Dockerfile"        ;;
    api)            ctx="."               file="api/Dockerfile"             ;;
    # natadeco の頁を描く Node(2026-09-03)。Elixir が HTML の要求だけ
    # ここへ回す。IMAGE_PREFIX=natadeco で焼く。
    ssr)            ctx="web-natadeco"    file="web-natadeco/Dockerfile"    ;;
    bun)            ctx="bun"             file="bun/Dockerfile"             ;;
    anubis)         ctx="config/anubis"   file="config/anubis/Dockerfile"   ;;
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

if [ "$#" -eq 0 ]; then echo "usage: $0 <combined|api|ssr|bun|anubis>..." >&2; exit 1; fi

# image を焼くためのツリーは ~/sukhi-images。
# ここは毎回まるごと消して展開し直すから。
echo "→ ship committed tree (HEAD=$SHA) to box"
git archive HEAD | ssh "$BOX" 'rm -rf ~/sukhi-images && mkdir -p ~/sukhi-images && tar -x -C ~/sukhi-images'

echo "→ login registry on box"
echo "$REGPASS" | ssh "$BOX" "docker login $REG -u $REGUSER --password-stdin >/dev/null"

for name in "$@"; do build_one "$name"; done

echo "✓ pushed: $*  (next: haloy deploy -t <target>, in sukhi-deploy)"

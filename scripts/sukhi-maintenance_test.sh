#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/sukhi-maintenance を、偽のコンテナ道具と偽の gateway で通して確かめる(`make test-maintenance`)。
# 偽の「podman」は、`exec [-i] NAME …` の … を、この木の web-next でそのまま走らせる。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
sm="$here/sukhi-maintenance"
work="$(mktemp -d)"
trap 'kill $gw_pid 2>/dev/null || true; rm -rf "$work"' EXIT
export SUKHI_LANG=en

# 偽の podman。FAKE_DOWN=1 のときは、コンテナが無いふりをする。
cat > "$work/podman" <<SH
#!/usr/bin/env bash
[ "\${FAKE_DOWN:-0}" = 1 ] && { echo "Error: no container with name or ID" >&2; exit 125; }
[ "\$1" = exec ] || exit 64; shift
[ "\$1" = -i ] && shift
shift   # コンテナ名
cd "$repo/web-next" && exec "\$@"
SH
chmod +x "$work/podman"
export SUKHI_CONTAINER_CLI="$work/podman"
export SUKHI_MAINT_DIR="$work/m"
mkdir -p "$SUKHI_MAINT_DIR"

# 偽の gateway(公開タイムラインだけ)。
cat > "$work/gw.mjs" <<'JS'
import { createServer } from 'node:http';
const posts = [
  { id: '1', visibility: 'public', content: '<p>あさのひかり</p>', account: { acct: 'hina', display_name: 'ひな' } },
  { id: '2', visibility: 'private', content: '<p>ひみつ</p>', account: { acct: 'hina', display_name: 'ひな' } }
];
createServer((req, res) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(posts)); })
  .listen(Number(process.argv[2]), '127.0.0.1');
JS
port=$((30000 + RANDOM % 10000))
node "$work/gw.mjs" "$port" & gw_pid=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
export GATEWAY_URL="http://127.0.0.1:$port"

fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=1; }
has()  { grep -q -- "$2" "$1" 2>/dev/null; }
page() { echo "$SUKHI_MAINT_DIR/www/maintenance.$1.html"; }

echo "# prepare"
"$sm" prepare >"$work/out" 2>&1 || { cat "$work/out"; bad "prepare"; }
[ ! -e "$SUKHI_MAINT_DIR/on" ] && ok "prepare sets no flag" || bad "prepare sets no flag"
for l in ja ko en; do has "$(page $l)" "<html lang=\"$l\">" && ok "plain $l page" || bad "plain $l page"; done
has "$(page ja)" 'あさのひかり' && bad "plain page has no posts" || ok "plain page has no posts"

echo "# on"
"$sm" on --why backup --about 30 --yes >"$work/out" 2>&1 || { cat "$work/out"; bad "on exits 0"; }
[ -f "$SUKHI_MAINT_DIR/on" ] && ok "flag set" || bad "flag set"
has "$work/out" 'copied 1 public posts' && ok "copied only the public post" || { cat "$work/out"; bad "copied only the public post"; }
has "$(page ja)" 'あさのひかり' && ok "ja page has the post" || bad "ja page has the post"
has "$(page ja)" 'ひみつ' && bad "private post stays out" || ok "private post stays out"
has "$(page ja)" 'バックアップ' && has "$(page ja)" '半刻ほどで' && ok "why and about in ja" || bad "why and about in ja"
has "$(page en)" 'We’re making a backup' && ok "why in en" || bad "why in en"
has "$(page ko)" '백업' && ok "why in ko" || bad "why in ko"
has "$SUKHI_MAINT_DIR/on" 'why=backup' && has "$SUKHI_MAINT_DIR/on" 'list=1' && ok "state recorded" || bad "state recorded"
"$sm" status > "$work/out"; has "$work/out" 'flag     set' && has "$work/out" 'copy     1 posts' && ok "status while on" || { cat "$work/out"; bad "status while on"; }
ls "$SUKHI_MAINT_DIR/www" | grep -q '^\.' && bad "no half-written files left" || ok "no half-written files left"
stat -c %a "$(page ja)" | grep -q '^644$' && ok "page is world-readable (nginx)" || bad "page is world-readable (nginx)"

echo "# off"
"$sm" off >"$work/out" 2>&1 || bad "off exits 0"
[ ! -e "$SUKHI_MAINT_DIR/on" ] && ok "flag removed" || bad "flag removed"
has "$(page ja)" 'あさのひかり' && bad "copy of posts is gone after off" || ok "copy of posts is gone after off"
has "$(page ja)" '<html lang="ja">' && ok "plain page is back" || bad "plain page is back"
"$sm" off >"$work/out" 2>&1; has "$work/out" 'was not set' && ok "off twice is fine" || bad "off twice is fine"

echo "# on --no-list / gateway down / web-next down"
"$sm" on --no-list --yes >/dev/null 2>&1; has "$(page ja)" 'あさのひかり' && bad "--no-list" || ok "--no-list has no posts"
has "$(page ja)" 'まだ決まっていません' && ok "no --about says so" || bad "no --about says so"
"$sm" off >/dev/null 2>&1
GATEWAY_URL=http://127.0.0.1:1 "$sm" on --yes >"$work/out" 2>&1 && ok "gateway down: still on" || bad "gateway down: still on"
has "$work/out" 'could not copy the posts' && ok "gateway down: warns" || bad "gateway down: warns"
has "$(page ja)" 'メンテナンス中です' && ok "gateway down: page without list" || bad "gateway down: page without list"
"$sm" off >/dev/null 2>&1

"$sm" prepare >/dev/null 2>&1
"$sm" on --yes >/dev/null 2>&1   # 写し入りの頁を置く
FAKE_DOWN=1 "$sm" on --why update --yes >"$work/out" 2>&1 && ok "web-next down: flag still set" || bad "web-next down: flag still set"
[ -f "$SUKHI_MAINT_DIR/on" ] && ok "web-next down: flag exists" || bad "web-next down: flag exists"
has "$work/out" 'could not build' && ok "web-next down: warns" || bad "web-next down: warns"
has "$(page ja)" 'あさのひかり' && ok "web-next down: previous page kept" || bad "web-next down: previous page kept"
FAKE_DOWN=1 "$sm" off >"$work/out" 2>&1 || bad "off with web-next down exits 0"
[ ! -e "$SUKHI_MAINT_DIR/on" ] && ok "web-next down: flag removed" || bad "web-next down: flag removed"
ls "$SUKHI_MAINT_DIR/www"/maintenance.*.html >/dev/null 2>&1 && bad "web-next down: pages holding the copy are deleted on off" || ok "web-next down: pages holding the copy are deleted on off"

echo "# arguments"
for args in "on --why because" "on --about soon" "on --bogus" "frobnicate" ""; do
  # shellcheck disable=SC2086
  "$sm" $args >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" = 2 ] && ok "exit 2 for: $args" || bad "exit 2 for: '$args' (got $rc)"
done
SUKHI_MAINT_DIR="$work/nowhere" "$sm" status >/dev/null 2>&1 && bad "missing dir" || ok "missing dir is an error"

echo "# Japanese"
SUKHI_LANG=ja "$sm" status >"$work/out" 2>&1; has "$work/out" '旗' && ok "ja messages" || bad "ja messages"

exit $fail

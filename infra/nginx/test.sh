#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-maintenance.conf を、本物の nginx に読ませて確かめる(`make test-nginx`)。
# 偽のアプリ(python)を後ろに立て、「止まっている」「旗が立っている」「アプリ自身の 503」を
# それぞれ作って、だれに何が返るかを見る。nginx が無ければ、そう言って 0 で終わる(CI で任意)。
#
#   NGINX=/usr/sbin/nginx  使う nginx(既定: PATH の nginx)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
nginx="${NGINX:-$(command -v nginx || true)}"
if [ -z "$nginx" ]; then echo "skip: nginx not found (set NGINX=…)"; exit 0; fi
command -v python3 >/dev/null || { echo "skip: python3 not found"; exit 0; }

root="$(mktemp -d)"
trap 'kill $(cat "$root/nginx.pid" 2>/dev/null) $app_pid 2>/dev/null || true; rm -rf "$root"' EXIT
mkdir -p "$root/m/www" "$root/conf" "$root/logs" "$root/acme"
# nginx の worker は別の uid で動く(root で始めると nobody)。mktemp の 0700 のままだと、旗も頁も見えない。
chmod 755 "$root"
maint="$root/m"
app_port=$((20000 + RANDOM % 10000)); ng_port=$((app_port + 1))

# 設定は、置き場だけを差し替えて使う(本物は /srv/sukhi-maintenance)。
# 写しの「新しい」期間(本物は 1 分)は 1 秒に縮める。そうしないと、古くなった写し(STALE)を見られない。
for f in sukhi-maintenance-gate.inc sukhi-maintenance-server.inc; do
  sed -e "s#/srv/sukhi-maintenance#$maint#g" -e 's#valid      200 1m#valid      200 1s#' "$here/$f" > "$root/conf/$f"
done
grep -q 'valid      200 1s' "$root/conf/sukhi-maintenance-gate.inc" || { echo "test setup: gate.inc changed shape"; exit 1; }
sed "s#/var/cache/nginx/sukhi-critical#$root/cache#" "$here/sukhi-maintenance.conf" > "$root/conf/sukhi-maintenance.conf"

# 偽のアプリ。/boom は自分で 503 を返す。
cat > "$root/app.py" <<PY
import http.server, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 503 if self.path == '/boom' else 200
        ctype, body = 'text/plain', b'app says hi' if code == 200 else b'app says no'
        if self.path.startswith('/nodeinfo/') or self.path.startswith('/.well-known/webfinger') or self.path == '/api/v1/instance':
            ctype, body = 'application/json', b'{"from":"app"}'
        if self.path == '/.well-known/host-meta':   # 確認の頁のような HTML が返ってきたとき
            ctype, body = 'text/html', b'<html>challenge</html>'
        if os.path.exists('$root/app-5xx'): code, body = 500, b'{"error":"boom"}'
        self.send_response(code); self.send_header('content-type', ctype); self.end_headers()
        self.wfile.write(body)
    do_POST = do_GET
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1', $app_port), H).serve_forever()
PY

cat > "$root/nginx.conf" <<CONF
pid $root/nginx.pid;
error_log $root/logs/error.log;
events {}
http {
  access_log off;
  types { text/html html; application/json json; }
  include $root/conf/sukhi-maintenance.conf;
  client_body_temp_path $root/tmp1; proxy_temp_path $root/tmp2; fastcgi_temp_path $root/tmp3; uwsgi_temp_path $root/tmp4; scgi_temp_path $root/tmp5;
  server {
    listen 127.0.0.1:$ng_port;
    include $root/conf/sukhi-maintenance-server.inc;
    location ^~ /.well-known/acme-challenge/ { root $root/acme; }
    location / {
      include $root/conf/sukhi-maintenance-gate.inc;
      proxy_pass http://127.0.0.1:$app_port;
    }
  }
}
CONF
"$nginx" -t -c "$root/nginx.conf" -e "$root/logs/error.log" >/dev/null 2>"$root/t.log" || { cat "$root/t.log"; exit 1; }

for l in ja ko en; do echo "<html lang=$l>page-$l</html>" > "$maint/www/maintenance.$l.html"; done
echo token > "$root/acme/.well-known-token"; mkdir -p "$root/acme/.well-known/acme-challenge"; echo ok-acme > "$root/acme/.well-known/acme-challenge/t"

"$nginx" -c "$root/nginx.conf" -e "$root/logs/error.log"
python3 "$root/app.py" & app_pid=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$app_port/" && break; sleep 0.1; done
base="http://127.0.0.1:$ng_port"

fail=0
# check NAME EXPECT_CODE EXPECT_BODY_REGEX EXPECT_HEADER_REGEX|- curl-args…
check() {
  local name="$1" code="$2" body="$3" hdr="$4"; shift 4
  local out; out="$(curl -s -i --max-time 5 "$@")"
  local got; got="$(printf '%s' "$out" | head -1 | awk '{print $2}')"
  local ok=1
  [ "$got" = "$code" ] || ok=0
  printf '%s' "$out" | grep -Eq -- "$body" || ok=0
  if [ "$hdr" != - ]; then printf '%s' "$out" | grep -Eiq -- "$hdr" || ok=0; fi
  if [ $ok = 1 ]; then echo "ok   $name"; else echo "FAIL $name (got $got)"; printf '%s\n' "$out" | sed 's/^/     /'; fail=1; fi
}

B='Accept: text/html,application/xhtml+xml'
echo "# アプリが動いている: そのまま通す"
check "app up"                200 'app says hi' - "$base/"
check "app's own 503 passes"  503 'app says no' - -H "$B" "$base/boom"

echo "# 大事な口(nodeinfo など): 動いている間に答えを置く"
check "nodeinfo live (MISS)"  200 'from' 'x-sukhi-cache: MISS' "$base/nodeinfo/2.0"
check "webfinger live"        200 'from' - "$base/.well-known/webfinger?resource=acct:a@b"
check "instance live"         200 'from' - "$base/api/v1/instance"
check "html answer is passed but never kept" 200 'challenge' - "$base/.well-known/host-meta"
check "nodeinfo 2nd request is a HIT"  200 'from' 'x-sukhi-cache: HIT' "$base/nodeinfo/2.0"

echo "# 旗が立っている: アプリが動いていても止める"
touch "$maint/on"
check "flag: browser gets the page (ja default)" 503 'page-ja' 'retry-after: 300' -H "$B" "$base/timeline"
check "flag: no-store"        503 'page-ja' 'cache-control: no-store' -H "$B" "$base/"
check "flag: noindex"         503 'page-ja' 'x-robots-tag: noindex' -H "$B" "$base/"
check "flag: Accept-Language en"      503 'page-en' - -H "$B" -H 'Accept-Language: en-GB,en;q=0.9' "$base/"
check "flag: Accept-Language ko"      503 'page-ko' - -H "$B" -H 'Accept-Language: ko-KR,ko;q=0.9' "$base/"
check "flag: unknown language -> en"  503 'page-en' - -H "$B" -H 'Accept-Language: fr-FR,fr;q=0.9' "$base/"
check "flag: fr then ko -> ko"        503 'page-ko' - -H "$B" -H 'Accept-Language: fr, ko;q=0.5' "$base/"
check "flag: cookie beats header"     503 'page-ko' - -H "$B" -H 'Accept-Language: en' -H 'Cookie: sukhi_locale=ko' "$base/"
check "flag: ?lang= beats cookie"     503 'page-en' - -H "$B" -H 'Cookie: sukhi_locale=ko' "$base/?lang=en"
check "flag: ?lang=garbage ignored"   503 'page-ja' - -H "$B" "$base/?lang=../../etc"
check "flag: HEAD"            503 '.' 'retry-after' -I -H "$B" "$base/"
check "flag: ActivityPub fetch gets JSON, not the page" 503 'maintenance' 'content-type: application/json' -H 'Accept: application/activity+json' "$base/users/hina"
check "flag: Accept with json and html -> JSON"  503 'maintenance' 'application/json' -H 'Accept: text/html, application/ld+json' "$base/users/hina"
check "flag: inbox POST"      503 'maintenance' 'content-type: application/json' -X POST -d '{}' "$base/inbox"
check "flag: API even for a browser Accept"  503 'maintenance' 'application/json' -H "$B" "$base/api/v1/timelines/public"
check "flag: other .well-known paths are JSON 503"  503 'maintenance' 'application/json' -H "$B" "$base/.well-known/x-other"
check "flag: webfinger is a critical door, still answered" 200 'from' - -H "$B" "$base/.well-known/webfinger?resource=acct:a@b"
check "flag: image request"   503 'maintenance' 'application/json' -H 'Accept: image/avif,image/*' "$base/uploads/a.png"
check "flag: certbot's path is not stopped" 200 'ok-acme' - "$base/.well-known/acme-challenge/t"
check "flag: nodeinfo is NOT stopped by the flag (app is up)" 200 'from' - "$base/nodeinfo/2.0"
check "flag: POST to nodeinfo path is not served from the cache" 503 'maintenance' 'application/json' -X POST -d x "$base/nodeinfo/2.0"
rm "$maint/on"
check "flag removed: app again"  200 'app says hi' - "$base/"

echo "# アプリが 5xx を返す: 大事な口は、置いてある写しで返す"
sleep 2   # 写しの「新しい」期間(1 秒)を過ぎさせる
touch "$root/app-5xx"
check "app 500: nodeinfo served stale" 200 'from' 'x-sukhi-cache: STALE' "$base/nodeinfo/2.0"
check "app 500: instance served stale" 200 'from' 'x-sukhi-cache: STALE' "$base/api/v1/instance"
check "app 500: a path never answered is the app's own 500" 500 'boom' - "$base/nodeinfo/9.9"
check "app 500: ordinary path is the app's own 500" 500 'boom' - "$base/timeline"
rm "$root/app-5xx"

echo "# アプリが止まっている(旗なし): 502 も同じ頁にする"
kill "$app_pid"; wait "$app_pid" 2>/dev/null || true; app_pid=
check "down: browser gets the page"  503 'page-ja' 'retry-after: 300' -H "$B" "$base/"
check "down: machine gets JSON"      503 'maintenance' 'application/json' "$base/api/v1/timelines/public"
check "down: nodeinfo served stale"  200 'from' 'x-sukhi-cache: STALE' "$base/nodeinfo/2.0"
check "down: webfinger served stale" 200 'from' 'x-sukhi-cache: STALE' "$base/.well-known/webfinger?resource=acct:a@b"
check "down: nodeinfo never fetched before -> JSON 503" 503 'maintenance' 'application/json' "$base/nodeinfo/2.1"
check "down: the HTML answer was not kept -> 503" 503 'maintenance' 'application/json' "$base/.well-known/host-meta"
touch "$maint/on"
check "down + flag: nodeinfo still served stale" 200 'from' 'x-sukhi-cache: STALE' "$base/nodeinfo/2.0"
check "down + flag: page for a browser"  503 'page-ja' - -H "$B" "$base/"
rm "$maint/on"

echo "# 頁を一度も用意していない"
rm "$maint/www/"*
check "JSON 503 when no page is prepared" 503 'maintenance' 'retry-after: 300' -H "$B" "$base/"

exit $fail

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-maintenance.conf を、本物の nginx に読ませて確かめる(`make test-nginx`)。
# 偽のアプリ(python)を後ろに立て、「止まっている」「旗が立っている」「nodeinfo だけ壊れている」
# 「アプリ自身の 5xx」をそれぞれ作って、だれに何が返るかを見る。
# nginx が無ければ、そう言って 0 で終わる(CI で任意)。
#
#   NGINX=/usr/sbin/nginx  使う nginx(既定: PATH の nginx)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
nginx="${NGINX:-$(command -v nginx || true)}"
if [ -z "$nginx" ]; then echo "skip: nginx not found (set NGINX=…)"; exit 0; fi
command -v python3 >/dev/null || { echo "skip: python3 not found"; exit 0; }

root="$(mktemp -d)"
app_pid=
trap 'kill $(cat "$root/nginx.pid" 2>/dev/null) $app_pid 2>/dev/null || true; rm -rf "$root"' EXIT
mkdir -p "$root/m/www" "$root/conf" "$root/logs"
# nginx の worker は別の uid で動く(root で始めると nobody)。mktemp の 0700 のままだと、旗も頁も見えない。
chmod 755 "$root"
maint="$root/m"
app_port=$((20000 + RANDOM % 10000)); ng_port=$((app_port + 1)); static_port=$((app_port + 2))

# 設定は、置き場・ポートだけを差し替えて使う(本物は /srv/sukhi-maintenance、8082、8083)。
# 診断の置き(本物は 5 秒)は 1 秒に縮める。そうしないと、直したあとの変化を待てない。
sub() {
  sed -e "s#/srv/sukhi-maintenance#$maint#g" \
      -e "s#127.0.0.1:8082#127.0.0.1:$app_port#g" \
      -e "s#127.0.0.1:8083#127.0.0.1:$static_port#g" \
      -e "s#/var/cache/nginx/sukhi-health#$root/cache-health#g" \
      -e 's#valid 200 5s#valid 200 1s#' -e 's#valid 500 501 502 503 504 2s#valid 500 501 502 503 504 1s#' "$1"
}
for f in sukhi-maintenance.conf sukhi-maintenance-gate.inc sukhi-maintenance-server.inc; do sub "$here/$f" > "$root/conf/$f"; done
# Link の在り処(空でよい。一度作っておく)。
: > "$maint/link.map"
grep -q 'valid 200 1s' "$root/conf/sukhi-maintenance-server.inc" || { echo "test setup: server.inc changed shape"; exit 1; }

# 偽のアプリ。
#   /boom /err500         自分で 503 / 500 を返す(このリクエストだけの失敗。nodeinfo は元気)
#   $root/nodeinfo-5xx    nodeinfo だけ 500 にする(診断が落ちる)
#   $root/nodeinfo-404    nodeinfo が 404(アプリは動いている)
#   $root/app-5xx         何を訊いても 500
cat > "$root/app.py" <<PY
import http.server, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code, ctype, body = 200, 'text/plain', b'app says hi'
        if self.path == '/boom': code, body = 503, b'app says no'
        if self.path == '/err500': code, body = 500, b'app broke here'
        if self.path.startswith('/nodeinfo/'):
            ctype, body = 'application/json', b'{"from":"app"}'
            if os.path.exists('$root/nodeinfo-5xx'): code, body = 500, b'{"error":"boom"}'
            if os.path.exists('$root/nodeinfo-404'): code, body = 404, b'{"error":"nope"}'
        if os.path.exists('$root/app-5xx'): code, body = 500, b'{"error":"boom"}'
        self.send_response(code); self.send_header('content-type', ctype); self.end_headers()
        self.wfile.write(body)
    do_POST = do_GET
    do_HEAD = do_GET
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
echo "secret" > "$maint/www/notes.txt"
# 眠っている間も答える文書(URL の道 + .json)。本物は mix sukhi.suspension.prepare が作り、scripts/sukhi-maintenance が置く。
mkdir -p "$maint/www/doc/users" "$maint/www/doc/.well-known" "$maint/www/doc/suspensions"
echo '{"id":"https://rest.example/users/ops","type":"Person","note":"stand-in-actor"}' > "$maint/www/doc/users/ops.json"
echo '{"subject":"https://rest.example","links":[{"rel":"https://w3id.org/fep/f799#deliveryController","href":"https://rest.example/users/ops"}]}' > "$maint/www/doc/.well-known/webfinger.json"
echo '{"id":"https://rest.example/inbox","deliveryController":"https://rest.example/users/ops"}' > "$maint/www/doc/inbox.json"
echo '{"id":"https://rest.example/suspensions/m1","type":"DeliverySuspension","note":"stand-in-notice"}' > "$maint/www/doc/suspensions/m1.json"
mkdir -p "$root/acme/.well-known/acme-challenge"; echo ok-acme > "$root/acme/.well-known/acme-challenge/t"

"$nginx" -c "$root/nginx.conf" -e "$root/logs/error.log"
python3 "$root/app.py" & app_pid=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$app_port/" && break; sleep 0.1; done
base="http://127.0.0.1:$ng_port"
static="http://127.0.0.1:$static_port"

fail=0
# check NAME EXPECT_CODE EXPECT_BODY_REGEX EXPECT_HEADER_REGEX|- curl-args…
check() {
  local name="$1" code="$2" body="$3" hdr="$4"; shift 4
  local out; out="$(curl -s -i --max-time 8 "$@")"
  local got; got="$(printf '%s' "$out" | head -1 | awk '{print $2}')"
  local ok=1
  [ "$got" = "$code" ] || ok=0
  printf '%s' "$out" | grep -Eq -- "$body" || ok=0
  if [ "$hdr" != - ]; then printf '%s' "$out" | grep -Eiq -- "$hdr" || ok=0; fi
  if [ $ok = 1 ]; then echo "ok   $name"; else echo "FAIL $name (got $got)"; printf '%s\n' "$out" | sed 's/^/     /'; fail=1; fi
}
# absent NAME HEADER curl-args… : そのヘッダーが付いていない
absent() {
  local name="$1" hdr="$2"; shift 2
  local out; out="$(curl -s -i --max-time 8 "$@")"
  if printf '%s' "$out" | grep -Eiq -- "^$hdr:"; then echo "FAIL $name"; printf '%s\n' "$out" | sed 's/^/     /'; fail=1; else echo "ok   $name"; fi
}
settle() { sleep 2.5; }   # 診断の置き(1 秒。nginx の時計は秒の粒)が切れるのを待つ

B='Accept: text/html,application/xhtml+xml'
echo "# アプリが動いている(nodeinfo が答える): そのまま通す"
check "app up"                200 'app says hi' - "$base/"
check "nodeinfo is the app's own answer"  200 'from' - "$base/nodeinfo/2.0"
check "app's own 503 passes (this request only)"  503 'app says no' - -H "$B" "$base/boom"
check "app's own 500 passes (nodeinfo is fine, so the server is not down)" 500 'app broke here' - -H "$B" "$base/err500"

echo "# 旗が立っている: アプリが動いていても止める。頁は静的サーバーから取ってくる"
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
check "flag: a conditional request still gets the body, not a 304"  503 'page-ja' - -H "$B" -H 'If-None-Match: "x"' -H 'If-Modified-Since: Wed, 01 Jan 2031 00:00:00 GMT' "$base/"
check "flag: ActivityPub fetch gets JSON, not the page" 503 'unavailable' 'content-type: application/json' -H 'Accept: application/activity+json' "$base/users/hina"
check "flag: Accept with json and html -> JSON"  503 'unavailable' 'application/json' -H 'Accept: text/html, application/ld+json' "$base/users/hina"
check "flag: inbox POST"      503 'unavailable' 'content-type: application/json' -X POST -d '{}' "$base/inbox"
check "flag: API even for a browser Accept"  503 'unavailable' 'application/json' -H "$B" "$base/api/v1/timelines/public"
check "flag: webfinger is an honest 503"     503 'unavailable' 'retry-after: 300' -H "$B" "$base/.well-known/webfinger?resource=acct:a@b"
check "flag: nodeinfo is an honest 503, not a kept answer" 503 'unavailable' 'application/json' "$base/nodeinfo/2.0"
check "flag: image request"   503 'unavailable' 'application/json' -H 'Accept: image/avif,image/*' "$base/uploads/a.png"
check "flag: certbot's path is not stopped" 200 'ok-acme' - "$base/.well-known/acme-challenge/t"

echo "# 旗が立っている: 眠っている間も、制御の文書とお知らせには 2xx で答える(FEP-f799)"
AP='Accept: application/activity+json'
check "doc: the actor is answered from the prepared file" 200 'stand-in-actor' 'content-type: application/json' -H "$AP" "$base/users/ops"
absent "doc: a 200 carries no Retry-After" 'retry-after' -H "$AP" "$base/users/ops"
check "doc: no-store"        200 'stand-in-actor' 'cache-control: no-store' -H "$AP" "$base/users/ops"
check "doc: HEAD"            200 '.' 'content-type: application/json' -I -H "$AP" "$base/users/ops"
check "doc: a plain Accept (*/*) is a machine too" 200 'stand-in-actor' - "$base/users/ops"
check "doc: the notice itself"       200 'stand-in-notice' - -H "$AP" "$base/suspensions/m1"
check "doc: WebFinger for the origin" 200 'deliveryController' - -H 'Accept: application/jrd+json' "$base/.well-known/webfinger?resource=https%3A%2F%2Frest.example"
check "doc: WebFinger for an acct: is not answered with the origin's" 503 'unavailable' 'retry-after: 300' -H 'Accept: application/jrd+json' "$base/.well-known/webfinger?resource=acct%3Abob%40rest.example"
check "doc: WebFinger without resource is not answered" 503 'unavailable' - -H 'Accept: application/jrd+json' "$base/.well-known/webfinger"
check "doc: POST to the inbox is still a 503 (the document is there, we are not receiving)" 503 'unavailable' 'retry-after: 300' -X POST -d '{}' "$base/inbox"
check "doc: GET of the same inbox URL is the collection" 200 'deliveryController' - -H "$AP" "$base/inbox"
check "doc: a browser at that URL does not get the JSON document" 503 'unavailable' 'retry-after: 300' -H "$B" "$base/users/ops"
check "doc: a path with no prepared file is an honest 503" 503 'unavailable' 'retry-after: 300' -H "$AP" "$base/users/nobody"
check "doc: odd characters are never passed on" 503 'unavailable' - -H "$AP" "$base/users/ops%20x"
check "doc: a directory-like path is a 503" 503 'unavailable' - -H "$AP" "$base/users/"
check "doc: the prepared file's name is not a way in" 503 'unavailable' - -H "$AP" "$base/users/ops.json"
rm "$maint/on"
check "flag removed: app again"  200 'app says hi' - "$base/"
check "app up: the app answers, not the stand-in" 200 'app says hi' - -H "$AP" "$base/users/ops"

echo "# Link: 休みのお知らせの在り処(link.map を書いて、nginx に読み直させる)"
touch "$maint/on"
absent "no Link while link.map is empty (machine)" 'link' -H "$AP" "$base/users/nobody"
LINK='<https://rest.example/suspensions/m1>; rel="https://w3id.org/fep/f799#deliverySuspension"'
printf '"~^" '"'"'%s'"'"';\n' "$LINK" > "$maint/link.map"
"$nginx" -c "$root/nginx.conf" -e "$root/logs/error.log" -s reload; sleep 1.5
check "Link on the machine 503"   503 'unavailable' 'link: <https://rest.example/suspensions/m1>; rel="https://w3id.org/fep/f799#deliverySuspension"' -H "$AP" "$base/users/nobody"
check "Link on the inbox POST"    503 'unavailable' 'link: <https://rest.example/suspensions/m1>' -X POST -d '{}' "$base/inbox"
check "Link on the page 503"      503 'page-ja' 'link: <https://rest.example/suspensions/m1>' -H "$B" "$base/"
absent "a 200 document carries no Link" 'link' -H "$AP" "$base/users/ops"
rm "$maint/on"
check "flag removed: no Link on the app's own answer" 200 'app says hi' - "$base/"
absent "app up: no Link" 'link' "$base/"

echo "# nodeinfo だけが壊れている(アプリは他には答える): それが「落ちている」の条件"
touch "$root/nodeinfo-5xx"; settle
check "nodeinfo 500: browser gets the page" 503 'page-ja' 'retry-after: 300' -H "$B" "$base/"
check "nodeinfo 500: nodeinfo itself says so honestly" 503 'unavailable' 'application/json' "$base/nodeinfo/2.0"
check "nodeinfo 500: API gets JSON 503" 503 'unavailable' 'application/json' "$base/api/v1/timelines/public"
rm "$root/nodeinfo-5xx"; settle
check "nodeinfo healed: app again" 200 'app says hi' - "$base/"

echo "# nodeinfo が 404(その機能が無いだけ): アプリは動いている"
touch "$root/nodeinfo-404"; settle
check "nodeinfo 404 is not 'down'"  200 'app says hi' - "$base/"
check "nodeinfo 404 passes through as the app's own answer" 404 'nope' - "$base/nodeinfo/2.0"
rm "$root/nodeinfo-404"; settle

echo "# 何を訊いても 5xx(nodeinfo も含む): 落ちている"
touch "$root/app-5xx"; settle
check "app 500: browser gets the page"  503 'page-ja' - -H "$B" "$base/timeline"
check "app 500: machine gets JSON"      503 'unavailable' 'application/json' "$base/api/v1/instance"
rm "$root/app-5xx"; settle
check "app healed"  200 'app says hi' - "$base/"

echo "# アプリが止まっている(旗なし)"
kill "$app_pid"; wait "$app_pid" 2>/dev/null || true; app_pid=
check "down: browser gets the page"  503 'page-ja' 'retry-after: 300' -H "$B" "$base/"
check "down: machine gets JSON"      503 'unavailable' 'application/json' "$base/api/v1/timelines/public"
check "down: nodeinfo says it is down" 503 'unavailable' 'retry-after: 300' "$base/nodeinfo/2.0"
check "down: POST gets JSON"         503 'unavailable' 'application/json' -X POST -d x "$base/inbox"
check "down: the control document is still answered" 200 'stand-in-actor' - -H "$AP" "$base/users/ops"
check "down: the notice is still answered" 200 'stand-in-notice' - -H "$AP" "$base/suspensions/m1"
check "down: the Link is on the 503" 503 'unavailable' 'link: <https://rest.example/suspensions/m1>' "$base/api/v1/timelines/public"

echo "# 静的サーバー"
check "static server serves the page files"  200 'page-ja' - "$static/maintenance.ja.html"
check "static server serves nothing else"    404 '.' - "$static/notes.txt"
check "static server: no directory listing"  404 '.' - "$static/"
check "static server serves a prepared document" 200 'stand-in-actor' - "$static/doc/users/ops.json"
check "static server: no document, no file"  404 '.' - "$static/doc/users/nobody.json"
check "static server: documents are read-only" 403 '.' - -X POST -d x "$static/doc/users/ops.json"
check "static server: only .json under /doc" 404 '.' - "$static/doc/notes.txt"

echo "# 頁を一度も用意していない"
rm "$maint/www/maintenance."*.html
check "JSON 503 when no page is prepared" 503 'unavailable' 'retry-after: 300' -H "$B" "$base/"

exit $fail

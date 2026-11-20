# SPDX-License-Identifier: AGPL-3.0-or-later
#
# server ブロックの直下に一度だけ:
#
#     include /etc/nginx/sukhi-maintenance-server.inc;
#
# アプリが答えられないとき(旗が立っている・nodeinfo が答えない・つながらない・時間切れ)は、
# どれも 503 にそろえて @sukhi_maint_* で答える。
# アプリ自身が返した 4xx / 5xx(proxy_intercept_errors は既定の off)は、そのまま通る ──
# 「このリクエストだけ失敗した」と「サーバーが落ちている」を、混ぜない。
# 500 を含めるのは、auth_request の診断が「5xx」だったときに nginx が作る 500 を拾うため。
#
# 最初の行き先 @sukhi_maint_first_* は、`=` のあとに状態の数字を書かない。そうすると、行き先の答えの
# 数字がそのまま出る ── 文書(FEP-f799 の制御の文書)には 200 を返せる。頁と JSON は、自分で 503 に戻す。
error_page 500 502 503 504 = @sukhi_maint_first_$sukhi_maint_try;
# 頁を取りに行った先(静的サーバー)がだめだったとき、JSON の 503 へ落とすのに要る。
recursive_error_pages on;

# ── 診断: nodeinfo が動いているか ────────────────────────────────
# 「動いていない」= つながらない・時間切れ・5xx。2xx と、4xx・3xx(アプリは答えている)は「動いている」。
# 行き先(proxy_pass)は、アプリへ通す location と同じにそろえる(RUNTIME.ja.md §9 の例では Anubis の 127.0.0.1:8082)。
location = /_sukhi/health {
    internal;
    proxy_pass http://127.0.0.1:8082/nodeinfo/2.0;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Accept "application/json";
    proxy_connect_timeout 2s;
    proxy_read_timeout 3s;

    proxy_cache sukhi_health;
    proxy_cache_key "nodeinfo";
    proxy_cache_valid 200 5s;
    proxy_cache_valid 500 501 502 503 504 2s;
    proxy_cache_lock on;
    proxy_ignore_headers Cache-Control Expires Set-Cookie Vary;

    proxy_intercept_errors on;
    error_page 301 302 307 308 400 401 403 404 405 429 = @sukhi_health_ok;
}

location @sukhi_health_ok {
    return 204;
}

# ── 最初の行き先 ─────────────────────────────────────────────────
# 眠っている間も答える文書を、静的サーバーに探しに行く(GET/HEAD の機械向けだけ。$sukhi_maint_try)。
# あれば 200。なければ(404 など)、これまでどおりの 503(頁か JSON。$sukhi_maint_kind)へ。
location @sukhi_maint_first_doc {
    proxy_pass http://sukhi_maint_static/doc$uri.json;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header If-None-Match "";
    proxy_set_header If-Modified-Since "";
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_hide_header ETag;
    proxy_hide_header Last-Modified;
    proxy_connect_timeout 2s;
    proxy_read_timeout 5s;

    # 代わりの文書。あとで本物の答えに戻る。残さない。
    add_header Cache-Control "no-store" always;
    add_header X-Robots-Tag  "noindex"  always;

    proxy_intercept_errors on;
    error_page 400 403 404 405 500 502 503 504 =503 @sukhi_maint_$sukhi_maint_kind;
}

# 文書を探さないもの(POST・人の窓・WebFinger の acct:)は、そのまま 503 へ。
location @sukhi_maint_first_none {
    error_page 503 =503 @sukhi_maint_$sukhi_maint_kind;
    return 503;
}

# ── 人の窓(GET/HEAD)には、静的サーバーの頁を取りに行く ─────────────
location @sukhi_maint_page {
    proxy_pass http://sukhi_maint_static/maintenance.$sukhi_maint_lang.html;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    # 条件つきリクエスト(304)にしない。いつも本体を返す。
    proxy_set_header If-None-Match "";
    proxy_set_header If-Modified-Since "";
    proxy_hide_header ETag;
    proxy_hide_header Last-Modified;
    proxy_connect_timeout 2s;
    proxy_read_timeout 5s;

    # 同じ URL が、あとで普通の頁になる。残さない。
    add_header Retry-After    300                                  always;
    add_header Cache-Control  "no-store"                           always;
    add_header X-Robots-Tag   "noindex"                            always;
    add_header Vary           "Accept, Accept-Language, Cookie"    always;
    # 休みのお知らせの在り処(FEP-f799)。$sukhi_maint_link が空なら、添えない。
    add_header Link           $sukhi_maint_link                    always;

    # 静的サーバーが答えない・頁が無い(まだ一度も用意していない)ときは、JSON の 503 へ。
    proxy_intercept_errors on;
    error_page 404 500 502 503 504 = @sukhi_maint_machine;
}

# ── ほかのすべて(連合の相手・アプリ・POST・画像)には、短い JSON を ──
# 落ちているときは落ちていると、正直に言う(nodeinfo も同じ。古い答えや作り話は返さない)。
# ファイルにしないのは、静的ファイルは POST に 405 を返してしまうため。
location @sukhi_maint_machine {
    default_type application/json;
    add_header Retry-After    300          always;
    add_header Cache-Control  "no-store"   always;
    add_header X-Robots-Tag   "noindex"    always;
    add_header Link           $sukhi_maint_link always;
    return 503 '{"error":"unavailable","retry_after":300}\n';
}

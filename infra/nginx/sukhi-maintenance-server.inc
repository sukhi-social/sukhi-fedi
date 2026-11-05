# SPDX-License-Identifier: AGPL-3.0-or-later
#
# server ブロックの直下に一度だけ:
#
#     include /etc/nginx/sukhi-maintenance-server.inc;
#
# アプリが答えられないとき(旗が立っている・止まっている・つながらない・時間切れ)、
# 502 / 503 / 504 のどれも、503 にそろえて @sukhi_maint で答える。
# アプリ自身が返した 503(proxy_intercept_errors は既定の off)は、そのまま通る。
error_page 502 503 504 =503 @sukhi_maint_$sukhi_maint_kind;

# 人の窓(GET/HEAD)には、置いてある頁を。
location @sukhi_maint_page {
    root /srv/sukhi-maintenance/www;

    # 同じ URL が、あとで普通の頁になる。残さない。
    add_header Retry-After    300                                  always;
    add_header Cache-Control  "no-store"                           always;
    add_header X-Robots-Tag   "noindex"                            always;
    add_header Vary           "Accept, Accept-Language, Cookie"    always;

    # 置いたファイルが無ければ(まだ一度も用意していない)、素の 503 へ。
    try_files /maintenance.$sukhi_maint_lang.html @sukhi_maint_machine;
}

# ほかのすべて(連合の相手・アプリ・POST・画像)には、短い JSON を。
# ファイルにしないのは、静的ファイルは POST に 405 を返してしまうため。
location @sukhi_maint_machine {
    default_type application/json;
    add_header Retry-After    300          always;
    add_header Cache-Control  "no-store"   always;
    add_header X-Robots-Tag   "noindex"    always;
    return 503 '{"error":"maintenance","retry_after":300}\n';
}

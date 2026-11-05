# SPDX-License-Identifier: AGPL-3.0-or-later
#
# アプリへ通す location(`location / { … }` など)の中に、一行だけ入れる:
#
#     include /etc/nginx/sukhi-maintenance-gate.inc;
#
# 二つのことをする:
#   ① 旗(/srv/sukhi-maintenance/on)があるあいだ、アプリへは通さず 503 にする(行き先は @sukhi_maint_*)。
#      ただし nodeinfo など「一番大事な口」(sukhi-maintenance.conf の $sukhi_crit_cache)は止めない。
#      旗があってもアプリが起きていればそのまま、止まっていれば置いてある写しを返す。
#   ② その口だけ、答えを短く置いておき、奥が 5xx・時間切れのとき、置いてあるもので返す。
#
# location の中に置くのは、certbot の /.well-known/acme-challenge/ のような、
# 別の location が受ける道まで止めないため(server の直下に置くと、証明書の更新も止まる)。

set $sukhi_gate "";
if (-f /srv/sukhi-maintenance/on) { set $sukhi_gate "on"; }
if ($sukhi_crit_cache != off)     { set $sukhi_gate "${sukhi_gate}-crit"; }
if ($sukhi_gate = on)             { return 503; }

proxy_cache            $sukhi_crit_cache;
proxy_cache_key        "$scheme://$host$request_uri";
proxy_cache_valid      200 1m;
proxy_cache_lock       on;
proxy_cache_use_stale  error timeout invalid_header updating http_500 http_502 http_503 http_504;
proxy_no_cache         $sukhi_crit_nocache;
add_header             X-Sukhi-Cache $upstream_cache_status;

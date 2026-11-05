# SPDX-License-Identifier: AGPL-3.0-or-later
#
# アプリへ通す location(`location / { … }` など)の中に、一行だけ入れる:
#
#     include /etc/nginx/sukhi-maintenance-gate.inc;
#
# 通す前に、二つを見る:
#   ① 旗(/srv/sukhi-maintenance/on)がある → 503(予定した停止)
#   ② nodeinfo が答えない(つながらない・時間切れ・5xx)→ 503(アプリが動いていない)
#      診断は sukhi-maintenance-server.inc の /_sukhi/health。2〜5 秒の置きがある。
# 503 になったあとの行き先(頁か JSON か)は sukhi-maintenance-server.inc の error_page。
#
# location の中に置くのは、certbot の /.well-known/acme-challenge/ のような、
# 別の location が受ける道まで止めないため(server の直下に置くと、証明書の更新も止まる)。
if (-f /srv/sukhi-maintenance/on) {
    return 503;
}
auth_request /_sukhi/health;

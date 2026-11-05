# SPDX-License-Identifier: AGPL-3.0-or-later
#
# アプリへ通す location(`location / { … }` など)の中に、一行だけ入れる:
#
#     include /etc/nginx/sukhi-maintenance-gate.inc;
#
# 旗(/srv/sukhi-maintenance/on)があるあいだ、アプリへは通さず 503 にする(行き先は @sukhi_maint)。
# location の中に置くのは、certbot の /.well-known/acme-challenge/ のような、
# 別の location が受ける道まで止めないため(server の直下に置くと、証明書の更新も止まる)。
if (-f /srv/sukhi-maintenance/on) {
    return 503;
}

<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# ① サーバーの準備

> 入口は [`OPERATIONS.md`](OPERATIONS.md)。ここは**箱を用意して、守りの土台を作る**ところまで。
> 手順は一般的な要約で、**実機では試していない**。公式の手順を優先し、名前や住所は読み替える。

急がなくて大丈夫です。各節の終わりに「できたかの確かめ」を置きました。それが通れば、次へ。

## 0. 決めておくこと(5 分)

| 決めること | 目安 | 後から変えられるか |
| --- | --- | --- |
| **ドメイン名** | `example.tld` | **変えると、連合上の ID が迷子になる**(ENV.md)。最初のサインアップの前に、正しく決める |
| ストア | Datalevin(主軸)/ Postgres(維持) | 変えるには移行が要る(DATALEVIN.md「Switching an existing instance」) |
| 実行環境 | Podman(rootless、推奨)/ Docker | 変えられる(RUNTIME.md) |
| 玄関 | ホストの nginx(基準)/ cloudflared / Coolify | 変えられる |
| メール | SMTP を用意するか | あとからでもよいが、**なければ登録の確認コードがログにしか出ない** |
| メディアの置き場 | S3 互換(rustfs や R2 など) | 設定しなければ、アップロードは使えない(`not_configured`) |

## 1. 箱を選ぶ

- 小さな箱でも動く設計(Datalevin は 0.5 OCPU / 512 MB 向けの推奨値が `DATALEVIN.md` にある)。
  最初は、**メモリ 1 GB 以上、ディスク 20 GB 以上**だと、余裕をもって試せる(目安。実際の必要量は未計測)。
- OS は、更新が長く続く安定版を。Fedora / RHEL 系(Rocky など)か、Debian / Ubuntu の LTS。
  本番の箱は Rocky(`build-on-box.sh` のユーザー名から)。
- OCI での用意は Terraform と cloud-init が `infra/terraform*/` にある(SETUP.md「Production Deployment」)。

**確かめ:** `uname -m`(arm64 か x86_64 か)。使う image がその構成に出ているか、見ておく
(`combined` は今、arm64 の `sha-` タグのみ。RUNTIME.md §6)。

## 2. 最初の守り(SSH と利用者)

入る方法は [`OPERATING_OVER_SSH.md`](OPERATING_OVER_SSH.md)。サーバーの中では:

```bash
# 管理する人ごとに、自分の名前のユーザーを作って、鍵で入れるようにする(root で直接入らない)
sudo useradd -m -s /bin/bash <あなたの名前>
sudo mkdir -p ~<あなたの名前>/.ssh && sudo chmod 700 ~<あなたの名前>/.ssh
# 公開鍵を ~<あなたの名前>/.ssh/authorized_keys に置く(権限 600)
sudo usermod -aG wheel <あなたの名前>      # sudo を使えるように(Debian/Ubuntu は sudo グループ)

# /etc/ssh/sshd_config.d/10-sukhi.conf
#   PasswordAuthentication no
#   PermitRootLogin no
#   AllowUsers <あなたの名前>           # 入れる人を名指しする(増えたらここに足す)
sudo sshd -t && sudo systemctl reload sshd   # 設定を確かめてから反映。今の接続は切らない
```

**ユーザー名のこと。** サーバーごとに名前を変える必要はありません(変えても、守りはほとんど増えません)。
大事なのは**一人に一つ**の名前であること。誰が何をしたか、記録で読めるようになります。
共有の `admin` のようなアカウントは作らない。`root` は消せませんが、**直接は入れない**ようにしておきます
(`PermitRootLogin no`)。作業は、自分のユーザーから `sudo` で。

**大事:** 設定を変えたら、**今つないでいる画面を閉じる前に**、別の画面から入れることを確かめる。
入れなくなったときの命綱になる。

**確かめ:** 別の端末から `ssh <あなたの名前>@<箱>` で入れて、パスワードでは入れない。

## 3. 時計・ファイアウォール・更新

```bash
# 時計(署名やログの時刻が狂わないように)
timedatectl status        # System clock synchronized: yes

# ファイアウォール(開けるのは 22, 80, 443 だけ)
sudo firewall-cmd --permanent --add-service=ssh --add-service=http --add-service=https
sudo firewall-cmd --reload     # Debian/Ubuntu なら ufw

# 自動の安全更新(OS の部品を、アプリと独立に新しく保つ)
sudo dnf install -y dnf-automatic          # Debian/Ubuntu: unattended-upgrades
# /etc/dnf/automatic.conf で apply_updates = yes(セキュリティのみにするなら upgrade_type = security)
sudo systemctl enable --now dnf-automatic.timer
```

自動更新は**玄関(nginx、sshd)を速く直す**ための土台(RUNTIME.md §11)。
カーネルの更新は再起動が要るので、月に一度、静かな時間に(OPS_MAINTAIN.md)。

**確かめ:** `systemctl list-timers | grep dnf`、`sudo firewall-cmd --list-all`。

## 4. 実行環境と玄関

- 実行環境(Podman か Docker)の導入: [`RUNTIME.md`](RUNTIME.md) §3。
- 玄関(nginx と証明書): [`RUNTIME.md`](RUNTIME.md) §9。**`Host` をそのまま渡す**ことが大事(署名に使われる)。

**確かめ:** `podman --version`(または `docker compose version` が 2.24 以上)、`sudo nginx -t`。

## 5. ドメインと DNS

- `DOMAIN` を箱に向ける(A / AAAA)。変更の反映には時間がかかることがある。
- WebFinger(`/.well-known/webfinger`)と ActivityPub が通るよう、**同じ名前で https**。リダイレクトで名前を変えない。

**確かめ:** `dig +short example.tld`。証明書は `certbot --nginx -d example.tld`(RUNTIME.md §9.3)。

## 6. 秘密と設定

`.env` を作る(リポジトリの `.env.example` から)。**最低限、自分で用意するもの**(ENV.md の「Minimum viable env」):

```bash
DOMAIN=example.tld
INSTANCE_TITLE="…"
ERLANG_COOKIE="$(openssl rand -hex 32)"      # 既定のままだと起動しない(安全のため)
SECRET_KEY_BASE="$(openssl rand -hex 64)"
SUKHI_VERSION=sha-<commit>                   # 本番は固定して使う(OPS_DEPLOY.md)
# Datalevin 構成:
SUKHI_STORE=datalevin
# メール(任意だが、なければ確認コードはログにだけ出る)
SMTP_HOST=…  SMTP_USERNAME=…  SMTP_PASSWORD=…  MAIL_FROM=no-reply@example.tld
```

- `.env` は **権限 600**、リポジトリに入れない、チャットに貼らない。
- 秘密はファイルで渡す方法もある(`/run/secrets` に 1 変数 1 ファイル。`combined/rel/entrypoint.sh`)。
- 設定の一覧は [`ENV.md`](ENV.md)。小さな箱の Datalevin の値は [`DATALEVIN.md`](DATALEVIN.md)。

**確かめ:** `make env-audit`(リポジトリの環境変数の整合を見る)。`ls -l .env` が `-rw-------`。

## 7. 置き場所(データ)

| もの | 場所 | 控えが要るか |
| --- | --- | --- |
| Datalevin(本体のデータ) | `DATALEVIN_DIR`(既定 `/var/lib/sukhi/datalevin`) | **要る**(OPS_MAINTAIN.md §3) |
| 配信キュー(SQLite) | `SUKHI_QUEUE_DB`(既定 `/var/lib/sukhi/queue.db`) | 要る |
| 原本・メディア | S3 互換(rustfs など) | 要る |
| ログ | コンテナのログ(`infra/logrotate` で回す) | 任意 |

ディスクは、**この場所に十分な空き**があること。`DATALEVIN_MAP_SIZE_MB`(既定 1024)は上限なので、データが近づく前に上げる。

**確かめ:** `df -h /var/lib/sukhi`。

## 8. 準備ができたか(まとめの確かめ)

- [ ] 鍵だけで入れる(パスワードでは入れない)
- [ ] 自動の安全更新が有効
- [ ] 80/443/22 だけ開いている
- [ ] `DOMAIN` が箱を指していて、https が通る
- [ ] `.env` の秘密が自分で作ったもので、権限が 600
- [ ] 置き場所の空きに余裕がある
- [ ] **控えの行き先を決めた**(OPS_MAINTAIN.md §3。まだ動かさなくてよいが、決めておく)

全部に印が付いたら、[`OPS_DEPLOY.md`](OPS_DEPLOY.md) へ。

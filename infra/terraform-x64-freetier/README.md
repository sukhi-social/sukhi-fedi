# sukhi-fedi on OCI x64 Always Free

`VM.Standard.E2.1.Micro` (1 OCPU, 1 GB RAM, x86_64) 一台に
`nodeinfo_monitor` アドオンを乗せる構成。ARM64 スタック
(`infra/terraform/`) とは独立。

**プロビジョニング: Terraform → cloud-init → docker compose + Watchtower。**

## メモリ予算

| 要素 | 目標 |
|---|---|
| OS + dockerd | 180 MB |
| postgres | 120 MB (`shared_buffers=48MB`) |
| nats | 30 MB |
| gateway (BEAM) | 250 MB (ERL_FLAGS チューン済) |
| delivery (BEAM) | 150 MB |
| bun | 100 MB |
| watchtower | 48 MB |
| cloudflared | 30 MB (ホスト側 systemd) |
| **合計** | **908 MB / 1024 MB** |

余裕 116 MB + swap 2 GB。`api` のみ `profiles: ["disabled"]` で除外。

## 手順

### 1. Terraform で VM を立てる (cloud-init 含む)

```bash
cd infra/terraform-x64-freetier

# tfvars を対話で生成 (~/.oci/config + API から自動抽出)
./bootstrap-tfvars.sh
# or 手動で:
# cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars

terraform init
terraform apply
```

共通テンプレート `../cloud-init.yaml.tmpl` が `user_data` に焼かれて、
初回起動時に以下を自動実行：

- `apt upgrade` + Docker CE + compose plugin (arch 自動判定)
- `deploy` ユーザ作成 (SSH公開鍵注入、docker/sudo グループ)
- `/swapfile` 2 GB + `vm.swappiness=10`
- `/dev/sdb` を ext4 で `/mnt/data` にマウント + `postgres/` `nats/` 作成
- UFW (deny incoming, allow SSH のみ、Cloudflare Tunnel 前提)
- sysctl (`file-max=524288`, `somaxconn=4096`)

### 2. 完了を待つ

```bash
ssh ubuntu@$(terraform output -raw instance_public_ip) 'cloud-init status --wait'
# → status: done
#   (初回は 3-5 分程度)
```

### 3. アプリ層のデプロイ

```bash
IP=$(terraform output -raw instance_public_ip)

scp ../../docker-compose.yml \
    ../../docker-compose.x64-freetier.yml \
    ../../.env.x64-freetier.example \
    deploy@$IP:~/

ssh deploy@$IP
# ↓ VM 内で
mv .env.x64-freetier.example .env
$EDITOR .env                          # DOMAIN / ERLANG_COOKIE 埋める
docker compose \
  -f docker-compose.yml \
  -f docker-compose.x64-freetier.yml \
  up -d
```

これで完了。以降は **Watchtower が `:v1` タグを定期的に pull して、
新しいイメージがあれば gateway/delivery/bun を自動再起動**する
(`WATCHTOWER_POLL_INTERVAL=3600` = 1時間毎、`.env` で調整可)。

### 4. Cloudflare Tunnel (ホスト側)

`docker-compose` に同梱していないので、ホスト側に `cloudflared` を入れる。

```bash
# VM 内で (deploy ユーザ or ubuntu)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cf.deb
sudo dpkg -i /tmp/cf.deb
sudo cloudflared service install <TUNNEL_TOKEN>
# Zero Trust ダッシュボードで tunnel の public hostname を
# http://localhost:4000 に向ける
```

## 検証

```bash
# プロビジョニング完了確認
ssh ubuntu@$IP 'cloud-init status --wait && free -h && lsblk && docker --version'
# 期待: cloud-init done / Total 957Mi Swap 2.0Gi / /dev/sdb mounted to /mnt/data

# コンテナ起動確認
ssh deploy@$IP 'docker compose -f docker-compose.yml -f docker-compose.x64-freetier.yml ps'
# 期待: postgres / nats / gateway / delivery / bun / watchtower (api は無し)

# メモリ使用量
ssh deploy@$IP 'docker stats --no-stream'
# 各 limit 内に収まっていること

# アプリ疎通
ssh deploy@$IP 'curl -s http://localhost:4000/.well-known/nodeinfo | jq .'

# nodeinfo_monitor 監視対象登録 (直投入)
ssh deploy@$IP 'docker compose exec -T postgres psql -U postgres -d sukhi_fedi -c \
  "INSERT INTO monitored_instances (domain, state, inserted_at, updated_at) \
   VALUES ('\''mastodon.social'\'', '\''active'\'', now(), now());"'

# Oban cron 発火後 (~50 min) スナップショット確認
ssh deploy@$IP 'docker compose exec -T postgres psql -U postgres -d sukhi_fedi -c \
  "SELECT domain, software_name, software_version, fetched_at \
   FROM nodeinfo_snapshots ORDER BY fetched_at DESC LIMIT 5;"'
```

## Watchtower の動き

- `:v1` など rolling tag を `SUKHI_VERSION` に指定している間、GHCR 上の
  タグ先頭が動くと Watchtower が検知して pull + 再作成
- `postgres` / `nats` は watchtower label がついていないので**無視される**
  (勝手に再起動されたら DB が飛ぶので意図的)
- 緊急で pin したい時は `.env` の `SUKHI_VERSION=v1.2.3` に変更して
  `docker compose up -d`

## トラブルシュート

- **`cloud-init status` が `error` になる**: `ssh ubuntu@$IP 'sudo cat /var/log/cloud-init-output.log | tail -80'` でログ見る
- **OOM**: `docker stats` で食ってるコンテナ特定。ERL_FLAGS の `+MBsbct` を更に下げる、`DB_POOL_SIZE` を更に絞る
- **"Out of host capacity"**: E2.1.Micro は free tier 枯渇しがち。別 AD / 別 region で再 apply
- **Watchtower が更新しない**: `docker logs watchtower` でエラー確認。private registry だと `WATCHTOWER_DOCKERHUB_PASSWORD` 系の資格情報必要

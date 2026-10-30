<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# コンテナ実行環境の導入と、SSH での更新(正本の案)

> 状態: **案。** haloy などの配備ツールに頼らず、**素の Docker / Podman / nerdctl と SSH だけ**で
> 導入と更新ができる、という正本にする提案。導入コマンドは各公式の手順を優先し、ここの記述は
> **このセッションでは実機で試していない**(読み替えて使う)。
> 入り方は [`OPERATING_OVER_SSH.md`](OPERATING_OVER_SSH.md)、更新の設計は [`SERVER_SHELL.md`](SERVER_SHELL.md)。

## 1. 考え方

- **正本は「Compose ファイル + image のダイジェスト + SSH で一回の再起動」。** 配備専用のツールは要らない。
  haloy のような仕組みは、本番の運用者が**任意で**使うもので、手順書の前提にしない。
- 実行環境(Docker / Podman / nerdctl)は選べる。**どれを選んでも、更新の手順の形は同じ**にする:
  「検証 → 新しい image を取得 → 再作成 → 確認」。
- 更新は、サーバーに SSH で入って `sukhi release`(設計は SERVER_SHELL.md §5.1)を実行する。
  中で呼ぶのは、下の実行環境ごとのコマンドだけ。

## 2. どれを選ぶか

| | Docker Engine | Podman | nerdctl(containerd) |
| --- | --- | --- | --- |
| 何か | 定番。デーモンが常駐 | デーモンなし。rootless が得意。systemd と相性がよい | containerd 用の Docker 互換 CLI |
| 画面 | (別途 Portainer など) | **Fedora なら Cockpit + `cockpit-podman`** でブラウザから見られる(下記) | なし |
| Compose | `docker compose`(v2.24 以降が必要) | `podman compose`(中で docker-compose か podman-compose を呼ぶ) | `nerdctl compose` |
| 向く人 | 手順の情報が一番多い。迷ったらこれ | Fedora / RHEL 系、デーモンを持ちたくない、systemd で管理したい | すでに containerd(k8s 周り)に慣れている |

**Compose の注意(要確認):** Datalevin 構成は `docker compose -f docker-compose.yml -f docker-compose.combined.yml -f docker-compose.datalevin.yml up -d` で、
`docker-compose.datalevin.yml` が Compose 2.24 以降の `!override` を使っている。
Podman と nerdctl で同じ重ね合わせが通るかは**未確認**(`podman compose` が呼ぶ側の Compose の版に左右される。
`nerdctl compose` の `!override` 対応も未確認)。実装の前に三つで通ることを試す(§7)。
通らない場合は、`docker compose config` で**重ね合わせ済みの一枚**を出して配る手がある。

## 3. 導入

> 以下は一般的な手順の要約。**公式の最新の手順を優先する。**

### 3.1 Docker Engine

公式のリポジトリから入れる(ディストリのパッケージは古いことがある)。
Fedora の例:

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
docker compose version        # v2.24 以上であること
```

自分を `docker` グループに入れると `sudo` なしで使える。**ただし docker グループは実質 root と同じ**なので、
管理者だけに。

### 3.2 Podman(Fedora では Cockpit の画面つき)

```bash
sudo dnf install -y podman podman-compose cockpit cockpit-podman
sudo systemctl enable --now cockpit.socket     # https://<サーバー>:9090 でブラウザから
podman --version
```

- Cockpit の画面から、コンテナの一覧、ログ、再起動、image の取得ができる。**見る・止める・再起動する**用途に便利。
  SSH でトンネルを張って見る(`ssh -L 9090:localhost:9090 sukhi`)と、9090 を外に開けなくて済む。
- **rootless**(一般ユーザーで動かす)が既定でおすすめ。1024 未満のポートは使えないので、
  4000 番で動かし、前段のリバースプロキシ(Anubis など)から転送する。
- 常駐させるなら **Quadlet**(systemd のユニットとして書く)が Podman 流。再起動時の自動起動と、ログの扱いが systemd に揃う。
  ただし Quadlet は Compose とは別の書式になるので、**正本は Compose に置き、Quadlet は派生**とする(§7)。
- ユーザーを閉じても動かし続けるには `loginctl enable-linger <ユーザー>`。

### 3.3 nerdctl(containerd)

```bash
# 公式リリースの nerdctl-full(containerd・CNI・BuildKit を含む)を展開する
# https://github.com/containerd/nerdctl/releases
nerdctl --version
nerdctl compose version
```

rootless は `containerd-rootless-setuptool.sh install`。画面はない。

## 4. 初回の起動

```bash
git clone https://github.com/sukhi-social/sukhi-fedi && cd sukhi-fedi
cp .env.example .env            # ERLANG_COOKIE などを必ず変える(docs/ENV.md)
# 実行環境に応じて、docker / podman / nerdctl のどれか:
docker compose -f docker-compose.yml -f docker-compose.combined.yml -f docker-compose.datalevin.yml up -d
```

image の取得先と版は `.env` の `SUKHI_VERSION`。**本番では `sha-<commit>` か、ダイジェスト固定にする**(§5)。

## 5. 更新(SSH で入って、再起動する)

`sukhi release` の中で行うことを、手で書くとこうなる。**どの実行環境でも、同じ四拍子。**

```bash
# 0. 入る(tmux の中で)
ssh sukhi && tmux new -s update

# 1. 検証: 「このリポジトリの main の workflow が焼いたもの」か(SERVER_SHELL.md §5.8)
cosign verify ghcr.io/<owner>/sukhi-fedi-combined@sha256:<ダイジェスト> \
  --certificate-identity "https://github.com/sukhi-social/sukhi-fedi/.github/workflows/combined-sha.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# 2. 取得: .env の SUKHI_VERSION を新しいものに書き換えて、先に pull だけする(止まらない)
docker compose pull

# 3. 再作成: 変わったコンテナだけが作り直される(短い再起動)
docker compose up -d

# 4. 確認
docker compose ps
docker compose logs --tail=100 gateway
sukhi status
```

Podman / nerdctl は、先頭の `docker` を `podman` / `nerdctl` に替えるだけ(§2 の注意が通っていれば)。

**戻し:** `.env` を前の版に書き戻して、手順 2〜3 をもう一度。
データベースの変更を含む版のときは、書き戻すだけでは戻らないことがある(SERVER_SHELL.md §5.6)。

### 5.1 Podman 流の自動更新

Podman には `podman auto-update` があり、Quadlet や systemd のユニットと組み合わせて、
新しい image を取得し、起動に失敗したら**前の image に自動で戻す**ことができる。
Watchtower の archive(SERVER_SHELL.md §5.9)の代わりに、Podman を選んだ人にはこれが自然な選択肢になる。
ただし、これは署名の検証(上の手順 1)をしない。**自動更新を使うなら、検証つきの `sukhi release` とは別物**と書いておく。
(Podman の `policy.json` の `sigstoreSigned` で署名の検証を入れられるが、GitHub Actions の keyless 署名の
身元(workflow の URI)を表せるかは**未確認**。)

## 6. 見つかった食い違い(確認が要る)

- `docker-compose.combined.yml` は `ghcr.io/<owner>/sukhi-fedi-combined:${SUKHI_VERSION:-v1}` を指すが、
  `release.yml` の対象に `combined` はない。`combined` を出すのは `combined-sha.yml` で、
  **`linux/arm64` のみ、`sha-<commit>` タグのみ**。そのため、x64 の機械で公開 image だけを使って Datalevin 構成を立てる道が、
  いまのところ見つからなかった(別の経路があれば教えてほしい)。
  正本を「素の Docker/Podman/nerdctl + Compose」にするなら、**combined を multi-arch で、semver タグで出す**
  ことが前提になる。
- 同じ理由で、`.env.example` の既定(`v1`)が実在するタグを指しているかも確かめる。

## 7. Podman を既定にする案

> 提案(ひなた): Podman を既定にしたい。デーモンレスを安定させられれば、サーバー管理に利点がある。

**利点(サーバー管理として)**
- **常駐するデーモンがない。** Docker は root のデーモンが落ちるとすべて巻き込まれ、`docker` グループが実質 root になる。
  Podman は rootless で、コンテナは一般ユーザーの一つのプロセスとして systemd の下に並ぶ。**攻撃面と「落ちたときの影響範囲」が小さい。**
- **systemd が見張り役になる**(Quadlet)。自動起動、再起動、ログ(journald)が OS の流儀に揃う。`sukhi` はこの状態を読むだけで済む。
- **Fedora なら Cockpit の画面**がある。SSH 前提の運用(OPERATING_OVER_SSH.md)と合う: 画面は見る・止める用、更新は SSH。
- `podman auto-update` が、起動に失敗したら前の image に自動で戻る(署名の検証はしない。§5.1)。

**気をつけること(実際にここで引っかかりそうな点)**
| 点 | 内容 | 対応 |
| --- | --- | --- |
| Compose の重ね合わせ | Datalevin 構成が `!override` を使う(§2) | 三つの環境で通すテストを CI に入れる。通らなければ、重ね合わせ済みの一枚を出す |
| メモリ上限 | `docker-compose.combined.yml` は小さな箱向けにメモリ上限を付けている。rootless では、ユーザーへの cgroup v2 の委譲(memory)がないと効かない | 導入手順に委譲の設定を書く。効いているかを `sukhi status` で見せる |
| SELinux(Fedora) | bind mount には `:Z` / `:z` が要る。付け忘れると書き込みで失敗する | Compose の volumes に付ける。Docker では無害 |
| 低いポート | rootless は 1024 未満を使えない | 4000 番で動かし、前段から転送(§3.2) |
| ディストリの版 | Quadlet は Podman 4.4 以降。Debian / Ubuntu の LTS は古いことがある | 対応する最低版を決めて書く |
| 運用の先例 | 本番(OCI の箱)は haloy + Docker 系で動いている | 移行は急がない。新規の自前ホストから Podman を既定に |

**推奨:** 手順書の**既定を Podman(rootless)**にする。ただし「既定」にするのは、次が揃ってから:
(1) Compose の重ね合わせが Podman で通る CI、(2) メモリ上限と SELinux の手順の実機確認、(3) `combined` の multi-arch 公開(§6)。
それまでは「Podman 推奨、Docker も対応」と書く。本番の箱は移行を強制しない。

**Quadlet の位置づけを見直す。** Podman が既定なら、デーモンの代わりに systemd が見張る Quadlet が自然な形になる(§3.2)。
Compose を正本に置いたまま、Quadlet は **Compose から生成**する(`podlet` のような変換ツールがある。出力の品質は未確認)。
先に Compose で通し、次の段階で Quadlet を足す。

## 8. eStargz(StarGZ)と部分取得

> 提案(ひなた): eStargz への対応は面白そう。

**何か(要約)。** eStargz は、ファイルごとに圧縮して目次を付ける形式で、必要なファイルだけを後から取れる(lazy pulling)。
Podman 側には、似た目的の **zstd:chunked** がある(目次を zstd の流れの中に入れる。unpack した中身のダイジェストは変わらない)。
どちらも、`containers/storage` の**部分取得**(partial pull)で、手元にあるファイルは再利用し、足りないものだけを HTTP の範囲指定で取る。

> 出典は Red Hat の解説(**2021 年 11 月**の記事)。当時は「実験的で既定では無効」。**いまの状況(既定になったか、eStargz をそのまま受け取れるか)は未確認。**
> 設定は `storage.conf` の `pull_options = {enable_partial_images = "true", …}` と、Linux 5.6 以降(`openat2`)が要る、と書かれている。
> 手元のファイルの再利用(reflink)は XFS / BTRFS のときだけ効く。

**sukhi での効きどころ**
- 更新のたびに取る image は、ほとんどが前回と同じファイル(Erlang のランタイム、依存、静的ファイル)で、変わるのは自分の `.beam` と設定。
  部分取得なら、**取得量と時間が大きく減る**見込み(減る量は未計測)。
- ただし**止まる時間は変わらない。** 更新は「先に pull → 差し替え」の順なので、取得は止まっている間ではなく前に済む(§5)。
  効くのは、回線が細い箱での更新の待ち時間と、転送量。
- **署名との関係:** 圧縮形式を変えるとマニフェストのダイジェストが変わる。署名は**配る形式のダイジェスト**に付ける。
  gzip 版と chunked 版を両方出すなら、それぞれ別に署名する(または一つに絞る)。

**進め方(提案)**
1. 先に**効果を測る**: いまの image を zstd:chunked(または eStargz)で出し直して、前回との差分取得量を測る。測らずに導入しない。
2. 出す側の確認: GHCR が範囲指定の取得を返すか、Actions の build がその形式を出せるか(BuildKit は eStargz を出せるが、zstd:chunked は buildah 側、のはずだが**未確認**)。
3. 取る側: Podman に `enable_partial_images` を設定(手順書に一行)。Docker などが取るときは従来の形式にフォールバックするので、
   **両対応の image を一つ出す**(マルチフォーマットではなく、既定の gzip を残す)かどうかを決める。
4. 本物の lazy pulling(起動しながら取る)は containerd + stargz-snapshotter(nerdctl 側)の仕事で、Podman の部分取得とは別物。
   nerdctl を選ぶ人向けの**任意の最適化**に留める。

## 9. コンテナの外に nginx を置く

> 提案(ひなた): コンテナの外に nginx の導入も書く。サーバーは「古き良き文化」と「静かに支えてくれる新技術」の共存で。

玄関(TLS と振り分け)は、長く使われて挙動がよく知られている **nginx をホストに直接**置く。
その奥の、入れ替わりの激しい部分(アプリ本体)をコンテナにする。玄関は変わらず、中身だけが静かに新しくなる。

```
インターネット ─▶ nginx(ホスト、443)─▶ Anubis(127.0.0.1:8080)─▶ gateway(コンテナ内 :4000)
                    TLS・Host の維持         /login だけ確認(docs/anubis.md)
```

これは `docker-compose.yml` の Anubis の注記(「edge は Anubis の 8080 に向ける」)と同じ形。

> 以下は一般的な手順の要約で、**実機では試していない。** 公式の手順を優先し、住所・ドメインは読み替える。

### 9.1 導入(Fedora / RHEL 系)

```bash
sudo dnf install -y nginx certbot python3-certbot-nginx
sudo systemctl enable --now nginx
sudo firewall-cmd --permanent --add-service=http --add-service=https && sudo firewall-cmd --reload
# SELinux が有効なとき、nginx が奥のポートへつなげるように
sudo setsebool -P httpd_can_network_connect 1
```

Debian / Ubuntu なら `sudo apt install nginx certbot python3-certbot-nginx`(SELinux の行は不要)。

### 9.2 設定の例

`/etc/nginx/conf.d/sukhi.conf`:

```nginx
server {
    listen 80;
    server_name example.tld;                 # DOMAIN と同じ名前
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name example.tld;

    # 証明書は certbot が書き込む(下の 9.3)
    ssl_certificate     /etc/letsencrypt/live/example.tld/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.tld/privkey.pem;

    # 画像や動画のアップロードの上限。アプリ側の上限(docs/ENV.md)と合わせる
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:8080;     # Anubis。直接 gateway(:4000)でもよい
        proxy_http_version 1.1;

        # 大事: 元の Host をそのまま渡す。ActivityPub の署名は Host も含めて確かめるので、
        # ここが変わると、他のサーバーからの配送が静かに受け付けられなくなる。
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # ストリーミング(WebSocket / 送りっぱなしの応答)
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }

    # タイムライン等のストリーミング。溜め込まず、長く待つ
    location /api/v1/streaming {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}

# http ブロック側(nginx.conf、または conf.d の先頭)に一度だけ
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

確かめてから反映する(**一度で壊さないための古い作法**):

```bash
sudo nginx -t && sudo systemctl reload nginx
```

`reload` は接続を切らずに設定を読み直す。アプリの更新のとき、玄関の nginx は止めなくてよい。

### 9.3 証明書

```bash
sudo certbot --nginx -d example.tld
```

更新は certbot のタイマーが自動で行う(`systemctl list-timers | grep certbot`)。
`DOMAIN` は**最初のサインアップの前に**正しい名前にしておく(変えると、連合上の ID が迷子になる。docs/ENV.md)。

### 9.4 コンテナ側(Anubis をローカルだけに出す)

nginx と同じホストからだけ届けばよいので、**外に開けない**:

```yaml
# docker-compose.override.yml(Podman でも同じ)
services:
  anubis:
    ports:
      - "127.0.0.1:8080:8080"
```

Podman(rootless)でも、1024 以上のポートなので、そのまま動く。

### 9.5 構成の選びかた

| 構成 | 玄関 | 向く場面 |
| --- | --- | --- |
| **ホストの nginx(推奨の基準)** | nginx + certbot | 自分の箱を持っている。古くからの手触りで、困ったときに調べやすい |
| Cloudflare Tunnel(cloudflared) | クラウド側 | 家庭回線、ポートを開けられない。compose の x64 free-tier 構成が使っている |
| Coolify などの配備基盤 | 基盤の内蔵 | すでに使っていて、その流儀に任せたい |

どれでも、奥(Anubis → gateway)は同じ。玄関だけを選ぶ。

## 10. 文体の方針(書き分け)

- **利用者に向けた文(画面、案内、告知、エラー)は和やかに。** 責めない、急かさない、次の一手を添える。
  更新の告知も、例えば「あと 10 分ほどで、ほんの少しのあいだ再起動します。そのまま使っていて大丈夫です」のように。
  (既存の `docs/KINDNESS.md` の考え方に揃える。)
- **サーバー管理者に向けた文(この文書、SSH の案内、設計)は、古くからの作法を大切に、新しい技術は静かに支える側に置く。**
  玄関は nginx、入り口は SSH、見張りは systemd、確認は `nginx -t` のように、長く効いてきたやり方を土台にして、
  署名の検証、部分取得、デーモンレスといった新しい仕組みは「そっと効いている」位置にとどめる。画面は見る・止める用で、更新は手で。
- 迷ったら、**読む人が一人で夜に開いても、落ち着いて進められるか**で決める。

## 11. CVE への備え: 「更新の持ち主」を一つにする

コンテナにしても、脆弱性の修正は**誰かが入れ直さないと届かない。** 変わるのは「誰が・何で入れ直すか」だけ。
更新の流れは三本ある。

| 流れ | 含まれるもの | 入れ方 | 放っておくと |
| --- | --- | --- | --- |
| ① ホスト OS | カーネル、glibc、OpenSSL、sshd、(ホストに置いた)nginx と certbot | `dnf-automatic` / `unattended-upgrades` | ホストの修正は入る。コンテナの中には**届かない** |
| ② コンテナの土台 | Alpine(musl)、イメージ内の OpenSSL、Erlang/OTP のランタイム | **イメージを焼き直して、入れ替える** | アプリを更新しない限り**古いまま** |
| ③ アプリの依存 | Hex、npm の依存 | 依存の更新 → ビルド → 入れ替え | 同上 |

コンテナ化とは、ライブラリを①から②へ**移す**こと。移したものは、①の自動更新では守られなくなる。
だから基準は「コンテナか否か」ではなく、**「そのものを、誰が、どれだけ速く入れ直せるか」**。

### nginx は外か中か

どちらも広く使われていて、**どちらが主流と言える数字は持っていない。**
コンテナ中心の構成(Kubernetes の ingress、compose で全部入り、Coolify など)では中に置くことが多く、
一台の箱をディストリで管理する古い流儀では外に置くことが多い。選ぶ理由は、流行ではなく**更新の持ち主**。

| | 外(ホスト、パッケージ) | 中(コンテナ) |
| --- | --- | --- |
| 脆弱性の修正 | ディストリの更新が自動で入る。`reload` で切れずに反映。アプリの更新と**独立** | 新しい image に入れ替えるまで届かない。ダイジェストで固定していると、自分で上げ続ける必要がある |
| 守備範囲 | nginx と、システム共通の OpenSSL が一度で直る | nginx と、その image の土台が別々 |
| 版 | ディストリ依存(古く見えても、修正は取り込まれる) | 好きな版を選べる |
| 向く場面 | 玄関。インターネットに最初に触れ、修正の頻度が高い | 構成ごと持ち運ぶ。環境を揃えたい |

**推奨(この構成の場合):**
- **玄関(nginx、sshd、certbot)はホストに置き、①の自動更新に乗せる。** 最も外に近く、修正が多く、止めずに直せる。
- **アプリ本体と Anubis はコンテナ。** こちらは②③の流れを、自分で用意する(下記)。
- **同じものを内と外の両方に置かない。** どちらが守られているか、わからなくなる。

### ②を放置しない仕組み

アプリの更新(main への push)を待たずに、**土台だけを焼き直す**道が要る。

1. **定期の再ビルド**: CI に週一回程度のスケジュール実行を足す(コードは同じで、土台だけが新しくなる)。
2. **脆弱性の走査**: ビルドごとに Trivy / Grype のような走査を通し、重大なものが見つかったら告知する(止めるかは別に決める)。
   SBOM(部品表)も出すと、「あの CVE は入っているか」に即答できる。
3. **`sukhi status` に出す**: image が焼かれてから何日か、ホストに未適用の更新・再起動要否(`needs-restarting -r` など)があるか。
   「古くなっている」が、一目でわかる(SERVER_SHELL.md §5.2 の計画にも出す)。
4. **反映**: 焼き直した image は、通常の `sukhi release`(検証 → 告知 → 再起動)で入れる。急ぎの修正は告知の時間を短くできる。
5. **ホストの更新で、コンテナが使うものが変わったとき**(カーネル、コンテナ実行環境の更新)は、再起動が要るかを同じ画面で見せる。

> 走査ツールの具体的な設定、再ビルドの頻度(週一でよいか)、重大度ごとの対応時間は、まだ決めていない。

## 12. 決めたいこと

1. **正本を「Compose + SSH」にして、haloy は任意の話に下げるか。** 推奨: そうする(本番の運用者は haloy を使い続けてよい)。
2. **既定の実行環境。** 推奨: **Podman(rootless)を既定にする**。ただし §7 の三条件が揃うまでは「Podman 推奨、Docker も対応」。
   nerdctl は「動く見込みで未検証」と明記。
3. **Quadlet。** 推奨: Compose から生成する形で、Compose が通ったあとの段階に足す。
4. **`combined` の multi-arch / semver 公開**(§6)。推奨: 出す。署名も同じ workflow で付ける。
5. **eStargz / zstd:chunked。** 推奨: まず測る(§8)。効果が出て、GHCR と CI が対応していれば、任意の最適化として足す。既定にはしない。
6. **玄関の基準。** 推奨: ホストの nginx + certbot を手順書の基準にする(§9)。cloudflared と Coolify は選択肢として併記。
   上の設定例は、実機で `nginx -t` を通してから確定する。
7. **CVE への備え。** 推奨: 玄関はホスト(自動更新)、アプリと Anubis はコンテナ、土台の焼き直しは CI の定期ビルド + 走査 + `sukhi status` での見える化(§11)。

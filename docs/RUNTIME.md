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

## 7. 決めたいこと

1. **正本を「Compose + SSH」にして、haloy は任意の話に下げるか。** 推奨: そうする(本番の運用者は haloy を使い続けてよい)。
2. **サポートする実行環境の範囲。** 推奨: Docker を基準(CI で通す)、Podman は Compose で通ることを確かめて「対応」、
   nerdctl は「動く見込みで未検証」と明記。画面が欲しい人には Fedora + Cockpit を案内。
3. **Quadlet を出すか。** 推奨: 最初は出さない。Compose を正本にして、要望が出たら生成する。
4. **`combined` の multi-arch / semver 公開**(§6)。推奨: 出す。署名も同じ workflow で付ける。

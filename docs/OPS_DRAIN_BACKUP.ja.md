<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# サーバーを切る前に、受付を止めて控えを取る

> **意図:** 計画して止めるとき(更新・再起動・移し替え)に、新しい書き込みと連合の受信を先に止め、動いている仕事を静かにしてから、Datalevin と配信キューの控えを取る。
> **読む人の困りごと(仮説):** 「いま止めて大丈夫? 投稿が途中で消えない? 控えは本当に開ける?」と、止める直前に不安になる。
>
> 状態: **実装済み・単体テスト済み。実機の `dtlv` では通していない**(未確認の一覧は §7)。
> 入口は [`OPS_MAINTAIN.ja.md`](OPS_MAINTAIN.ja.md) §3。更新の流れは [`OPS_QUADLET_GITOPS.md`](OPS_QUADLET_GITOPS.md) §7。

## 1. 一言で

```
 受付を止める ─▶ いまの通信が終わるのを待つ ─▶ 投稿の仕分け(outbox)を空にする
      │                                                   │
      ▼                                                   ▼
 書き込みは 503 + Retry-After        キューを止めて、動いている仕事が 0 になるのを待つ
 (読むのは今までどおり)                                   │
                                                          ▼
                                   控えを取る ─▶ 控えが開くか確かめる ─▶(あとは止める)
```

- **受付を止める**とは: 書き込み(`GET` `HEAD` `OPTIONS` 以外の全部)と、他サーバーからの受信(inbox)に **`503` と `Retry-After`** を返すこと。
  受信を `202` で受けてしまうと、相手は「届いた」と思って捨てる。`5xx` なら相手が持ったまま、あとでやり直す。**止めている間の連合は失われない。**
- 読むのは止めない。人からは「止まった」ではなく「いまは読むだけ」に見える。
- **どの段階で失敗しても、受付は止めたまま**。半端なまま開けるより、閉じたまま理由を読むほうが安全だから。やり直しても、`open` で戻してもよい。
- プロセスを止めるのはこの仕組みではなく、ユニット(`systemctl --user stop sukhi-gateway`)。`--stop` を付けたときだけ、すべて成功したあとに止める。

## 2. 使い方(箱の上で、ユーザー `sukhi` として)

```sh
scripts/sukhi-drain.sh status          # いまの様子。何も変えない
scripts/sukhi-drain.sh run             # 止める → 静かにする → 控え → 開くか確認(受付は止めたまま)
scripts/sukhi-drain.sh run --stop      # 上に加えて、すべて成功したらユニットを止める
scripts/sukhi-drain.sh open            # やめる。キューを再開して受付を戻す
```

`close`(止めて静かにするだけ)と `backup`(静かな状態の控えだけ)に分けても呼べる。オプション:
`--reason WORD`(訪れた人に見える一語。既定 `maintenance`)、`--retry SECS`(`Retry-After`、既定 300)、
`--until ISO8601`(戻る見込みの時刻)、`--timeout SECS`(仕分けの空き待ちとキューの静まり待ち、各 60 秒)。

- 中身は `podman exec sukhi-gateway /app/bin/combined rpc 'SukhiFedi.Maintenance.Drain.cli(:run)'`。
  cookie は秘密のファイル(`/run/secrets/ERLANG_COOKIE`)から、そのコンテナの中だけで読む。箱の上に出さない。
- **止まったまま・ユニットも止めない**のは、失敗したとき(終了コード 2)と、控えのあとの `SUKHI_BACKUP_HOOK` が失敗したとき(3)。
- `SUKHI_BACKUP_HOOK` は、控えができたあとに呼ぶ任意のコマンド。箱の外へ送る口。例:
  `SUKHI_BACKUP_HOOK='restic backup "$SUKHI_BACKUP_HOST_DIR"'`(`infra/backup/` の restic と同じ置き場に載せられる)。
- 更新(GitOps)の前に呼ぶなら `sukhi-drain.sh run`(`--stop` なし)。同期スクリプトがそのあと `try-restart` する。
  新しい gateway は**いつも開いた状態で起動する**ので、「開け忘れ」は起きない。

## 3. 何が止まり、何が止まらないか

| | 止まる? | 理由 |
|---|---|---|
| `POST` `PUT` `PATCH` `DELETE` の全部(投稿・ログイン・アップロード・管理) | **止まる** | `IntakePlug` が**メソッドで**断る。経路の一覧ではないので、来年足した書き込みも自動で止まる |
| 他サーバーの inbox への `POST` | **止まる(503)** | 上に同じ。相手が持ったまま再送する |
| `GET` / `HEAD` / `OPTIONS`(読む・CORS の下見) | 止まらない | 読み取り専用で見せるため |
| 通信中のリクエスト | 終わるまで待つ | `AdmissionQueue.running/0` が 0 になるまで。そのあと 3 秒の余裕(数えていない受信のため) |
| 仕分け待ちの投稿(`outbox` の `pending`、`outbox_dispatch` の仕事) | **流し切るまで待つ** | 流れ切れば、受け付けた投稿は全部 SQLite の配信キューにある。Datalevin と SQLite の「あいだ」に何も残らない |
| 配信の仕事(相手ごとに 1 件) | **待たない。キューを止める** | キューに残ったまま控えに入り、再起動後に再開する。落ちている相手を待つと何時間もかかる |
| Oban のキュー全部(gateway と delivery) | 止める | 動いている仕事が 0 になるまで待つ |
| Pull Federation の取り込み(puller) | 新しく始めない | 走っている分は終わるまで待つ |
| Oban の cron、メトリクスの採取、graph の写し、Pull の統計の書き出し | **止めない** | ユーザーのデータではなく、控えにも影響しない(`dtlv copy` も `VACUUM INTO` も、使っているデータベースで一貫した写しを取れる) |

## 4. 控えに入るもの(`SUKHI_BACKUP_DIR`、既定 `/var/lib/sukhi/backups/<UTC 時刻>/`)

| 中身 | 取り方 |
|---|---|
| `datalevin/`(`DATALEVIN_DIR`) | `dtlv -d <src> copy <dest>`。使用中でも取れる、と `dtlv` 自身のヘルプにある |
| `datalevin/graph/`(`SUKHI_GRAPH=1` のとき) | 同じ。もう一つの `dtlv` の環境なので別に取る |
| `datalevin/.sukhi-store.json` | ファイルコピー(カタログの指紋。復元後の起動検査が読む) |
| `queue.db` / `delivery_queue.db` | SQLite の `VACUUM INTO`。**ファイルを直接コピーしない** |
| `backup-manifest.json` | 既存の控えの目録(`Release.write_datalevin_backup_manifest!`)。復元後の検査がそのまま読む |
| `backup-info.json` | この回に取ったもの(大きさ、版、受付の状態) |

- 取り方の約束: `<時刻>.partial` で作り、**全部コピーして、開くか読み戻したあとで**名前を変える
  (`dtlv stat` を各コピーに、`PRAGMA quick_check` を各 SQLite に)。時刻だけの名前のディレクトリは、開けた控え。失敗したら partial を消す。
- 取る前にディスクの空き(元の 1.1 倍)を見て、足りなければ**何もコピーせずに**断る。
- 新しい控えが開けたあとで、古い控えを**最新の 3 つだけ残して**消す(`SukhiFedi.Maintenance.Backup.prune/2`)。消すのは時刻の名前で、中に自分の `backup-info.json` があるものだけ。ほかの人が置いたものは触らない。
- **入らないもの:** `SUKHI_RAW_BACKEND=s3` のときの原本(バケット側の版管理・複製で守る。`backup-info.json` の `raw_covered` で分かる)、
  `/etc/sukhi/instance.json`(目録に場所だけ書く)、`podman secret`(控えの置き場所ごとに秘密が増えるので、入れない。OPS_QUADLET_GITOPS.md §6)。
- 取り出した先の `dtlv` は**もう一つ起動する**(`-Xmx` は常駐の子と同じ)。0.5 OCPU / 512 MB の箱では、控えを取る間だけメモリが一時的に増える。空きを見てから回す。
- 受付を止めずに、いまの状態の控えだけ取りたいとき(夜の定期など)は `bin/combined rpc 'IO.inspect(SukhiFedi.Maintenance.Backup.run())'`。
  こちらは「止まっているか」を見ない(上の二つの道具が使用中でも一貫して取れるので)。

## 5. 「受付を止めた」という合図(読み取り専用のメンテナンス画面と共有する)

合図は**一か所**(`SukhiShared.Intake`)で持ち、二つの形で外に出る:

| 見る人 | 形 | 中身 |
|---|---|---|
| web-next などのフロント、外の見張り | `GET /.sukhi/intake.json`(gateway が答える。ドット始まりなので、どのフロントも取れない。ストアに触れないので、止まっている間も答える。`cache-control: no-store`) | `{"state":"open"\|"closed","since":…,"reason":…,"until":…,"retry_after_s":…}`。**パスも件数も控えの場所も出さない** |
| gateway が止まっている間の静的ページ(nginx など) | マーカーファイル `SUKHI_INTAKE_FILE`(既定 `/var/lib/sukhi/intake.json`、データボリューム上) | 上と同じ項目 + `settled_at` と `backup`(`dir` と時刻)。一時ファイル→rename で書くので、半端な内容は見えない |

- **マーカーはユニットが止まっても `closed` のまま残る**(「予定した停止」と「落ちた」を見分けられる)。次に gateway が起動したとき `open` に書き直す。
  つまり静的ページは「マーカーが `closed` で、gateway に届かない」ときに「メンテナンス中です」を出せばよい。マーカーが無い・古いときの扱いは見る側が決める。
- 起動した BEAM はいつも `open`。**受付の状態はディスクではなくプロセスのもの**にしたのは、更新のあとに誰も開け忘れず、
  止めている最中に落ちて再起動しても何も失われない(各段階はやり直せる)ため。
- 「いまは読むだけ」を画面に出したいフロントは、`/.sukhi/intake.json` を読み、`closed` なら投稿の入口を畳む。
  それまでは、書き込みが `503` と `{"error":"maintenance","retry_after":N}` で返る。

## 6. 戻す(復元)

控えは、戻せて初めて控え(OPS_MAINTAIN.ja.md §3.4)。手順(**実機で通していない**):

1. 古い書き手を止める(`systemctl --user stop sukhi-gateway`)。現在の `datalevin/` `queue.db` `delivery_queue.db` は、消さずに脇へ退ける。
2. 控えの `datalevin/` を `DATALEVIN_DIR` に、`queue.db` を `SUKHI_QUEUE_DB` の位置に、`delivery_queue.db` を `DELIVERY_QUEUE_DB` に戻す。
   `datalevin/graph/` は入れ子のまま `DATALEVIN_DIR/graph` へ。持ち主は元と同じ(`sukhi`)。
3. 控えの `backup-manifest.json` を `/var/lib/sukhi/backup-manifest.json` に置き、起動前に検査する:
   `podman run --rm … combined eval 'SukhiFedi.Release.check_datalevin_backup_manifest!()'`(DATALEVIN.md の「Switching an existing instance」と同じ)。
   カタログの指紋が違えば、起動が断られる。
4. 起動する。起動した gateway は開いている。ログに `datalevin store manifest` の警告が出ないこと、ログインして読めることを確かめる。

## 7. 未確認(正直に)

- **実機の `dtlv`(1.2.10)で `copy` / `stat` を回していない。** 引数の形(`-d SRC copy DEST`、`-d DEST stat`)は `dtlv` の公式ドキュメントのとおり。
  宛先ディレクトリを先に作っておいて受け付けるか、WAL(`DATALEVIN_DURABILITY=strict`)を含めてコピーされるか、`stat` が複製のどこまで読むか、は実機で確かめる。
  最初の一回は、本番ではなく同じ image の別の箱で `run`(`--stop` なし)を回し、§6 の手順で別の場所に戻して数を比べる。
- **`bin/combined rpc` が `RESULT` 行まで流すか**(リリースの `rpc` は式の出力だけを返す前提で書いた)。`status` で最初に確かめる。
- 0.5 OCPU の箱での、控えの所要時間と一時的なメモリ(§4)。
- `SUKHI_BACKUP_DIR` を既定のボリュームの外にした場合、`SUKHI_BACKUP_HOST_DIR` は空で hook が呼ばれる(スクリプトは警告する)。
- 複数ノード(Postgres 版の分割構成)では動かない。受付の状態は 1 つの BEAM のもので、Datalevin は書き手が一つ(combined)のため。Postgres 版の控えは `infra/backup/` のまま。

## 8. しくみ(読む人向け)

| 役 | 置き場所 |
|---|---|
| 受付の状態・合図(唯一の定義) | `shared/lib/sukhi_shared/intake.ex` — `closed?/0` を、HTTP の門・puller・手順が同じ関数で聞く |
| HTTP の門(メソッドで断る) | `elixir/lib/sukhi_fedi/web/intake_plug.ex`(`Router` で、レート制限のあと・本文を読む前) |
| 止める手順 | `elixir/lib/sukhi_fedi/maintenance/drain.ex` — 手順が触るものは `world/1` の関数に集め、順序とタイムアウトは DB なしでテストできる |
| 控え | `elixir/lib/sukhi_fedi/maintenance/backup.ex` |
| 箱の上の入口 | `scripts/sukhi-drain.sh`(入力を検査してから式を組み、`RESULT` 行で終了コードを決める) |

CODE_STYLE.md の「一か所」の約束どおり、「止まっているか」の判断は `Intake.closed?/0` だけ。呼び出し側がフラグを写して持つことはない。

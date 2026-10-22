# データの訂正 — 外部=再構築できるキャッシュ、内部=源泉

PostgreSQL に間違って入ったものを、後から直すための運用メモ。sukhi-fedi の
データは性質が二つに分かれていて、直し方もそれぞれ違う。

- **内部（local-origin）** — このサーバが生んだもの。ローカルユーザ、その投稿、
  フォロー意図、OAuth、設定。**取り返せない。** バックアップで守る対象
  （[`infra/backup/README.md`](../infra/backup/README.md)）。
- **外部（remote-origin）** — 他サーバからミラーしたもの。リモート actor の影、
  ミラーしたリモート note。**作り直せる** — origin から再取得、または受信原本
  アーカイブ（`inbound` バケット）から replay。

だから「外部データが壊れた」ときの第一手は、復元ではなく **捨てて作り直す**。
内部に触れずに、外部だけを。

## origin の見分け（コード上の定義）

origin は列で決まる。一箇所に寄せてある：

| | local | remote | 述語 |
|---|---|---|---|
| account | `domain IS NULL` | `domain` あり | `SukhiFedi.Accounts.{local,remote}_accounts/1` |
| note | `ap_id IS NULL`（その場で合成） | `ap_id` あり | `SukhiFedi.Notes.{local,remote}_notes/1` |

remote account のスキャンは部分インデックス
`accounts_remote_domain_index`（`domain IS NOT NULL`）で速い。remote note は
既存の `notes.ap_id` unique index がそのまま効く。

## 二軸のリカバリ（取り違えないこと）

| | 何をする | いつ | データ損失 |
|---|---|---|---|
| **外科的訂正** | 特定の行/列だけ直す | 「間違って入った」 | 無し。狙った所だけ |
| **全DB巻き戻し** | DB 全体を過去の一点へ | ホスト死亡・DB破損 | その時点以降の良い変更も失う |

ふだん欲しいのはほぼ **外科的訂正** のほう。全DB巻き戻し（restore / PITR）は
大災害用で、手順は [`infra/backup/README.md`](../infra/backup/README.md)。

## 道具（すべて gateway 上で `bin/sukhi_fedi rpc`、dry-run 先）

各モジュールの moduledoc に詳しい挙動と注意がある。

| 道具 | 直すもの | 一言 |
|---|---|---|
| `Maintenance.RebuildFromArchive` | remote note の取りこぼし列（cw / 公開時刻 / emoji） | 受信原本から replay、ネット不要。**まず試す**外科的訂正 |
| `Maintenance.RefetchActors` | remote actor の影（名前 / bio / avatar / emoji） | origin から再取得して in-place 更新。follow edge は保持 |
| `Maintenance.RebuildRemoteNotes` | pre-snowflake の古い id を持つ remote note | 再取得して id を振り直し、FK を catalog から辿って付け替え |
| `Maintenance.RebuildRemoteNoteIds` | created_at とズレた snowflake id（並び順バグ） | created_at から id を振り直し |
| `Maintenance.WipeRemote` | 壊れた remote note を丸ごと | ミラーを捨てる。`RebuildFromArchive` と組で「作り直し」 |

note の id を振り直す系（`RebuildRemoteNotes` / `RebuildRemoteNoteIds`）は、
新 id の行を入れて FK を付け替えてから旧行を消すので、reaction / boost /
スレッドは保たれる。スレッドは `ap_id` で繋がっていて id に依らない。

## 走っているあいだの進み具合

`:execute` で走らせると、`RebuildFromArchive` / `RefetchActors` / `RebuildRemoteNotes` /
`RebuildRemoteNoteIds` / `RebuildDirectVisibility` / `WipeRemote` は、
`maintenance_runs` に進み（対象件数・済んだ件数・うまくいかなかった件数・段階・開始時刻）を
約1秒に1回だけ書く（`Maintenance.Progress`）。`/admin` のトップが数秒おきに読んで見せる。
`:dry_run` は読むだけなので載らない（`RebuildDirectVisibility` は origin を引くので載る）。
進みの報告が途絶えた run は「止まったかもしれない」と表示し、断定はしない。
新しいスクリプトを足すときは `Progress.track/5`（または `start` / `map` / `finish`）で包む。

## 外部を捨てて作り直す（WipeRemote → Rebuild）

ピアが壊れた note データを送ってきて、列の上書きでは直しきれないとき。

```sh
# 1) 何が消えるか、必ず先に見る
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.WipeRemote.run(:dry_run)'
#    → %{remote_notes: N, cascades: [...{table, column}...], domain: nil}

# 2) 実行（remote note を削除、従属行は FK で cascade）
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.WipeRemote.run(:execute)'

# 3) 受信原本アーカイブから作り直す
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:execute)'
```

一つのピアだけを対象にするなら `domain:` を渡す：

```sh
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.WipeRemote.run(:dry_run, domain: "peer.example")'
```

### WipeRemote が触らないもの・触るもの

- **触らない**: accounts、follows。だから local のフォロー関係は wipe を跨いで
  生き残る。remote actor の影は別途 `RefetchActors` で直す
  （`follows.followee_id` が `RESTRICT` なので、フォロー中の remote account は
  そもそも消せない）。
- **触る（cascade）**: 消す note を参照する行 — boosts / bookmarks / reactions /
  pinned / note_tags / note_media / notifications / poll は `delete_all`、
  `reports.note_id` は `nilify_all`。scope は remote note だけ
  （`ap_id IS NOT NULL`）なので、local note は絶対に消えない。

### 正直な注意（dry-run が教えてくれる）

- **local の相互作用**: ローカルユーザが remote note に付けた reaction / boost /
  bookmark は、その note を参照しているので一緒に cascade で消える。作り直すと
  note は新しい id で戻るので、どのみち持ち越せなかったもの。個人インスタンスでは
  受容する前提。
- **アーカイブ未収録の note**: `inbound` に原本が無く（受信経路でなく fetch で
  入った等）、origin も既に消えている remote note は、wipe すると戻らない。
  これは **キャッシュのリセット** であって無損失の往復ではない。dry-run の件数を
  見てから実行すること。

## 確認手順（コピーDBで一度通す）

本番でいきなり叩かない。コピーに対して：

1. `WipeRemote.run(:dry_run)` の `remote_notes` 件数を控える
2. local の note / account の件数を控える（`SELECT count(*) FROM notes WHERE ap_id IS NULL` 等）
3. `WipeRemote.run(:execute)` → remote note が消え、**local の件数が不変**
4. `RebuildFromArchive.run(:execute)` → スレッドが `ap_id` で再リンクされる
5. timeline / スレッドが壊れていないこと

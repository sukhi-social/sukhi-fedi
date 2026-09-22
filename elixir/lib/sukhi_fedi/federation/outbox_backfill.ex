# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.OutboxBackfill do
  @moduledoc """
  こちらから remote を follow して `Accept` が返ったとき、相手の
  `outbox` を辿って過去の投稿を `notes` に取り込む（backfill）。

  これが無いと、新しく follow した相手のプロフィールは「まだ `Create` が
  届いていないぶん」だけの頁になる ── Mastodon は follow 時に相手の
  outbox を引くので、そこだけ挙動が違っていた。

  ## signed fetch が要る

  相手が authorized fetch / Mastodon Secure Mode を立てていると、署名の
  無い outbox 取得は 401/403 で弾かれる（`ff.lapy.link` は実際そう）。
  `CollectionFetcher.fetch/2` に `SukhiFedi.Accounts.signing_identity/0`
  を渡し、note の取得と同じ身元で引く。

  ## 取り込むもの、取り込まないもの

  `public` / `unlisted` の `Create(Note|Article|Question)` だけ。
  followers-only は follow が通っていても、こちらが持つ影の row を
  別のローカル利用者に見せてよい理由にはならない。`Announce`（相手の
  ブースト）は他所の note を指すので、ここでは辿らない。

  `ap_id` の unique index と `on_conflict: :nothing` で冪等 ── 何度
  走らせても増えない。

  ## 進行状態

  「その影の row の outbox を引いたか」は `accounts.backfill_*` に残す
  （`backfill_state` は `nil`/`"pending"`/`"running"`/`"done"`/`"failed"`）。
  `/admin/backfill` がこれを読む。再起動のたびに `pending_existing/0` が
  未着手と失敗を拾い直すので、古い follow も放っておけば追いつく。
  """

  use Oban.Worker, queue: :backfill, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  require Logger

  alias SukhiFedi.AP.Instructions.{Extract, Mirror}
  alias SukhiFedi.Federation.{ActorFetcher, CollectionFetcher}
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Follow}

  # 1 回で辿る頁と件数の上限。相手の outbox は数千件あることもあるので
  # 頭から数十件だけ。もっと要るならもう一度 enqueue する。
  @pages 3
  @items 60
  @unique_period_seconds 3_600

  @pending "pending"
  @running "running"
  @done "done"
  @failed "failed"

  # ── enqueue ──────────────────────────────────────────────────────────────

  @doc """
  `actor_uri` の outbox backfill を enqueue する。同じ相手の job が
  1 時間以内に居れば束ねる。未着手 / 失敗の row だけ `"pending"` に印を
  付ける（走っている最中に `"running"` を `"pending"` へ戻さない）。
  """
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(actor_uri) when is_binary(actor_uri) do
    # Insert first, mark after: if the insert raises, the row must stay
    # untouched/failed so the boot sweep retries it. Marking first would
    # strand it in `pending` with no job behind it.
    case %{"actor_uri" => actor_uri}
         |> new(unique: [period: @unique_period_seconds, keys: [:actor_uri]])
         |> then(&Oban.insert(SukhiFedi.Oban, &1)) do
      {:ok, _job} = ok ->
        mark_pending(actor_uri)
        ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  未着手 / 失敗の row だけ `"pending"` に印を付ける（走っている最中に
  `"running"` を `"pending"` へ戻さない）。`enqueue/1` と release task が使う。
  """
  @spec mark_pending(String.t()) :: :ok
  def mark_pending(actor_uri) when is_binary(actor_uri) do
    from(a in Account,
      where:
        a.actor_uri == ^actor_uri and (is_nil(a.backfill_state) or a.backfill_state == @failed)
    )
    |> Repo.update_all(set: [backfill_state: @pending, backfill_attempted_at: now()])

    :ok
  end

  @doc """
  未着手と失敗の followee を拾い直して enqueue する。

  古い follow は `maybe_handle_follow_accept/1` を通っていないので、
  これを一度走らせないと永久に静かなままになる。冪等 ── 何度呼んでも
  取り込みは増えない。
  """
  @spec pending_existing() :: :ok | {:error, term()}
  def pending_existing do
    from(a in Account,
      join: f in Follow,
      on: f.followee_id == a.id,
      where:
        f.state == "accepted" and not is_nil(a.domain) and not is_nil(a.actor_uri) and
          (is_nil(a.backfill_state) or a.backfill_state in [@pending, @failed]),
      group_by: a.id,
      select: a.actor_uri
    )
    |> Repo.all()
    |> Enum.each(&enqueue/1)

    :ok
  rescue
    error -> {:error, error}
  end

  @doc """
  起動時の一撃。boot 直後は `SukhiFedi.Oban` の registry がまだ
  登録されていないことがあるので、少し間を置いて数回粘る。全部駄目なら
  ログに残して次回の起動に任せる（`SukhiFedi.Application` が
  fire-and-forget で呼ぶ）。
  """
  @spec pending_existing_on_boot() :: :ok | {:error, term()}
  def pending_existing_on_boot do
    Enum.reduce_while(1..5, :ok, fn attempt, _acc ->
      Process.sleep(attempt * 500)

      case pending_existing() do
        :ok -> {:halt, :ok}
        {:error, _} = err when attempt == 5 -> {:halt, err}
        {:error, _} -> {:cont, :ok}
      end
    end)
    |> case do
      {:error, error} ->
        Logger.warning("OutboxBackfill: pending_existing_on_boot failed: #{inspect(error)}")
        {:error, error}

      other ->
        other
    end
  end

  # ── worker ───────────────────────────────────────────────────────────────

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"actor_uri" => actor_uri}}) do
    case Repo.get_by(Account, actor_uri: actor_uri) do
      nil ->
        :ok

      account ->
        mark(account, @running, mirrored: 0, error: nil)

        case run(actor_uri) do
          {:ok, mirrored} ->
            mark(account, @done, mirrored: mirrored, error: nil)
            :ok

          {:error, reason} ->
            mark(account, @failed, mirrored: 0, error: inspect(reason))
            {:error, reason}
        end
    end
  end

  @doc """
  同期実行。`perform/1` のほか、手元や IEx からその場で引くときにも使う。
  """
  @spec run(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(actor_uri) when is_binary(actor_uri) do
    with {:ok, outbox} <- outbox_of(actor_uri),
         {:ok, items, _meta} <- fetch_outbox(outbox) do
      {mirrored, seen} =
        Enum.reduce(items, {0, 0}, fn item, {mirrored, seen} ->
          if mirrorable?(item) do
            Mirror.maybe_mirror_create_note(item, false)
            {mirrored + 1, seen + 1}
          else
            {mirrored, seen + 1}
          end
        end)

      Logger.info("OutboxBackfill: #{actor_uri} mirrored #{mirrored}/#{seen}")
      {:ok, mirrored}
    end
  end

  defp outbox_of(actor_uri) do
    case ActorFetcher.fetch(actor_uri) do
      {:ok, %{"outbox" => outbox}} when is_binary(outbox) -> {:ok, outbox}
      {:ok, _} -> {:error, :no_outbox}
      {:error, _} = err -> err
    end
  end

  defp fetch_outbox(outbox) do
    CollectionFetcher.fetch(outbox,
      pages: @pages,
      items: @items,
      sign_as: SukhiFedi.Accounts.signing_identity()
    )
  end

  @doc false
  # outbox の 1 件が、取り込むべき `Create(Note|Article|Question)` か。
  # public / unlisted だけ ── followers-only は follow が通っていても、
  # こちらが持つ影の row を別のローカル利用者に見せてよい理由にならない。
  @spec mirrorable?(term()) :: boolean()
  def mirrorable?(%{"type" => "Create", "object" => %{"type" => type} = note})
      when type in ["Note", "Article", "Question"] do
    Extract.visibility_from(note) in SukhiFedi.Visibility.public_only()
  end

  def mirrorable?(_), do: false

  # ── 進行状態（/admin/backfill） ──────────────────────────────────────────

  @doc "Follow している remote の backfill 進行状態。admin の頁が読む。"
  @spec list() :: [Account.t()]
  def list do
    from(a in Account,
      join: f in Follow,
      on: f.followee_id == a.id,
      where: f.state == "accepted" and not is_nil(a.domain),
      group_by: a.id
    )
    |> Repo.all()
    # 手を打つ順に。終わったものより、まだ引けていないものを上に。
    |> Enum.sort_by(&{state_rank(&1.backfill_state), &1.username})
  end

  defp state_rank("failed"), do: 0
  defp state_rank(nil), do: 1
  defp state_rank("pending"), do: 2
  defp state_rank("running"), do: 3
  defp state_rank(_done), do: 4

  @doc "状態ごとの件数（未着手 = `nil`）。"
  @spec counts() :: %{atom() => non_neg_integer()}
  def counts do
    by_state =
      from(a in Account,
        join: f in Follow,
        on: f.followee_id == a.id,
        where: f.state == "accepted" and not is_nil(a.domain),
        group_by: a.backfill_state,
        select: {a.backfill_state, count(a.id, :distinct)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      untouched: Map.get(by_state, nil, 0),
      pending: Map.get(by_state, @pending, 0),
      running: Map.get(by_state, @running, 0),
      done: Map.get(by_state, @done, 0),
      failed: Map.get(by_state, @failed, 0)
    }
  end

  defp mark(%Account{id: id}, state, opts) do
    Repo.update_all(
      from(a in Account, where: a.id == ^id),
      set: [
        backfill_state: state,
        backfill_attempted_at: now(),
        backfill_mirrored: Keyword.get(opts, :mirrored, 0),
        backfill_error: Keyword.get(opts, :error)
      ]
    )

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

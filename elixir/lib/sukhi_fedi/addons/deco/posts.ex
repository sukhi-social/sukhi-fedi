# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Deco.Posts do
  @moduledoc """
  板の上に書かれたもの ── 立てる、返す、直す、消す、知らせる、読む。

  器のほうは `Deco.Boards`。本文・HTML 化・タグ・メディア・削除の
  実体は `SukhiFedi.Notes` のまま ── 同じものの道を二本作らないため。
  ここが足すのは「どの板か」と、掲示板としての読みかた(古い順、
  たたみ、話す板の流れ)だけ。

  読む口(`list_posts/2`・`get_post/2`)はトークンを要らないし、viewer で
  絞りもしない ── その約束は `SukhiFedi.Addons.Deco` に一枚だけ置いて
  ある。`viewer_id` を受けるのは反応の `me` を立てるためだけ。
  """

  import Ecto.Query

  alias SukhiFedi.{Notes, Notifications, Repo, Snowflake}
  alias SukhiFedi.Addons.Deco.{Boards, Federation, View}
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Notes.Create, as: NotesCreate
  alias SukhiFedi.Notes.Ids
  alias SukhiFedi.Schema.{Account, Deco, DecoNote, Note, Report}

  # 何人から知らせが届いたら、いったんたたむか。人数で数える(同じ人が
  # 何度言っても一人)。運営が見るまでのあいだの、読む人の側の手当て。
  @fold_after 3

  # ── 書く ─────────────────────────────────────────────────────────────

  @doc """
  板に一件書く。`params` は `%{"title" => _, "status" => _}`。板の一覧に
  並ぶのは題だけなので、無題だと一覧の上で見分けがつかない ── title は必須。
  返りは `list_posts/2` と同じ形。
  """
  @spec post(Account.t() | integer(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | atom() | {:validation, map()}}
  def post(author, slug, params) do
    with {:ok, %{id: deco_id, kind: kind}} <- Boards.get_deco(slug),
         :ok <- require_title(kind, params) do
      write(id_of(author), deco_id, params)
    end
  end

  # 題が要るのは「立てる」板だけ。話す板では、ひとこと置くのに
  # 見出しを考えさせない ── 一覧に並ぶのが題ではなく、書かれた言葉
  # そのものなので、無題でも見分けがつく。
  #
  # 話す板でも題は付けられる（要らないだけ）。題の有無がそのまま
  # 連合の形（`name` を持つかどうか）になるので、禁じない。
  defp require_title("talk", _params), do: :ok

  defp require_title(_kind, params) do
    params = stringify(params)

    case Map.get(params, "title") do
      t when is_binary(t) -> if String.trim(t) == "", do: title_missing(), else: :ok
      _ -> title_missing()
    end
  end

  defp title_missing, do: {:error, {:validation, %{title: ["を入れてください"]}}}

  @doc """
  板の投稿に、ぶら下げる。返信先は板の投稿そのものでも、その下の
  レス(自分のでも、連合越しに届いたものでも)でもいい ── 「誰に
  向けた返信か」は in_reply_to_id がそのまま持つので、深さは問わない。
  返信先自身に deco_notes の行が無い(連合越しの mirror)ときは、
  親をたどってどの板の話かを探す。
  """
  @spec reply(Account.t() | integer(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | atom() | {:validation, map()}}
  def reply(author, note_id, params) do
    with %Note{} = target <- Repo.get(Note, to_int(note_id)),
         deco_id when not is_nil(deco_id) <- deco_id_for_thread(target) do
      write(
        id_of(author),
        deco_id,
        Map.put(stringify(params), "in_reply_to_id", parent_ref(target)),
        # 返事の既定は、板ではなく親に従う。ローカルに置かれた話へ
        # 黙って外向きの返事が付くと、部屋の中の話がそこから出ていく。
        # 書く人が選べば、そちらが通るのは変わらない。
        parent_local_only(target)
      )
      |> notify_reply_author(target, id_of(author))
    else
      _ -> {:error, :not_found}
    end
  end

  # 返信が付いたら、返信先を書いた人に知らせる ── 種別は "mention" を
  # 借りる(Mastodon の通知種別に「板のレス」という専用枠が無いのと、
  # 直接ポケットを鳴らしてよい tier に既に入っているのが "mention" だけ
  # なので、WebPush.deliverable?/3 側の一覧は増やさずに済む)。
  # 自分自身への返信は Notifications.create/1 が黙って無視する。
  defp notify_reply_author({:ok, %{id: reply_note_id}} = result, %Note{account_id: recipient_id}, from_account_id) do
    Notifications.create(%{
      account_id: recipient_id,
      from_account_id: from_account_id,
      type: "mention",
      note_id: reply_note_id
    })

    result
  end

  defp notify_reply_author(result, _target, _from_account_id), do: result

  # 返信先そのものに deco_notes の行があればそれ。無ければ(連合越しの
  # mirror)そのまた親をたどって、いちばん近い板の行を探す。無限ループ
  # を避けるため、たどる深さに上限を付ける。
  @max_thread_walk 20

  @doc false
  # 外から届いた一件を板に結ぶとき、`Deco.Federation` も同じ遡りを使う
  # ── audience を名乗らない相手(Mastodon など)の道。
  def deco_id_for_thread(note), do: deco_id_for_thread(note, @max_thread_walk)
  defp deco_id_for_thread(_note, 0), do: nil

  defp deco_id_for_thread(%Note{id: id, in_reply_to_ap_id: parent_ap_id}, hops_left) do
    case Repo.get_by(DecoNote, note_id: id) do
      %DecoNote{deco_id: deco_id} ->
        deco_id

      nil ->
        with ap_id when is_binary(ap_id) <- parent_ap_id,
             %Note{} = parent <- Repo.get_by(Note, ap_id: ap_id) do
          deco_id_for_thread(parent, hops_left - 1)
        else
          _ -> nil
        end
    end
  end

  # 開設(INVITE_REQUIRED=false)は誰でも今すぐ入れる分、できたばかりの
  # アカウントが束にして書き込む道は塞いでおきたい。古参にはこの制限は
  # 掛からない ── 内部の目安であって、外に見せるバッジやランクにはしない。
  @new_account_window_h 24
  @new_account_min_gap_s 20

  # 板で選べる公開範囲は二つだけ ── 全域(連合に出す)か、ローカル
  # (natadeco の中だけ)。他の値・未指定は全域扱い。
  defp write(account_id, deco_id, params, default_local \\ nil)

  defp write(account_id, deco_id, params, default_local) when is_integer(account_id) do
    params = stringify(params)
    {i18n, rest} = Map.split(params, ["title_i18n", "content_i18n"])

    # 書く人が選べば、それが通る。選ばなければ板の既定 ── 一件ごとに
    # 訊かれ続けないための既定であって、板が決めてしまう錠ではない。
    # 長い文章として出すか。既定は Note ── 選んだ人だけ Article になる。
    as_article? = truthy(Map.get(rest, "as_article"))

    local_only? =
      case {Map.get(rest, "visibility"), default_local} do
        {"local", _} -> true
        {"public", _} -> false
        {_, nil} -> deco_local_default(deco_id)
        {_, inherited} -> inherited
      end
    # FEP-1b12 の `audience` ── どの板の投稿か。掲示板を持つ実装は
    # ここを読んで、板の中に置いてくれる。`to` には入れない: 入れると
    # Mastodon が板を silent mention として解決してしまうし、FEP-1b12 も
    # `audience` を本筋、`to` は既存実装の互換と書いている。
    #
    # 表札を出していない板は actor が引けないので、指し先を作らない。
    note_params =
      rest
      |> Map.put("local_only", local_only?)
      |> Map.put("as_article", as_article?)
      |> put_audience(deco_id)

    with :ok <- check_pace(account_id) do
      # note を先に作り、そのあと板に結ぶ。note づくりは Notes 側の
      # トランザクション（outbox 込み）なので、こちらでは包めない。
      # 結びに失敗したら note は消す ── どこにも属さない投稿を残さない。
      case Notes.create_status(account_id, Map.put(note_params, "visibility", "public")) do
        {:ok, note} ->
          %DecoNote{}
          |> DecoNote.changeset(
            Map.merge(
              %{
                "deco_id" => deco_id,
                "note_id" => note.id,
                "local_only" => local_only?,
                "as_article" => as_article?
              },
              i18n
            )
          )
          |> Repo.insert()
          |> case do
            {:ok, dn} ->
              # 板を追っている相手に、新しく立った話を配る（開き手だけ）。
              Federation.announce_new_post(deco_id, note.id)

              # `create_status/2` は `:account` を preload して返すので、
              # 書いた人をもう一度引きに行かなくていい。
              {:ok, post_view(note, dn, note.account)}

            {:error, cs} ->
              Notes.delete_note(account_id, note.id)
              {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_pace(account_id) do
    with %Account{created_at: created_at} <- Repo.get(Account, account_id),
         true <- new_account?(created_at),
         %DateTime{} = last <- last_post_at(account_id),
         true <- DateTime.diff(DateTime.utc_now(), last) < @new_account_min_gap_s do
      {:error, :rate_limited}
    else
      _ -> :ok
    end
  end

  defp new_account?(%DateTime{} = created_at) do
    DateTime.diff(DateTime.utc_now(), created_at, :hour) < @new_account_window_h
  end

  defp last_post_at(account_id) do
    Repo.one(
      from(dn in DecoNote,
        join: n in Note,
        on: n.id == dn.note_id,
        where: n.account_id == ^account_id,
        order_by: [desc: n.id],
        limit: 1,
        select: n.created_at
      )
    )
  end

  # ── 直す ─────────────────────────────────────────────────────────────

  @doc """
  自分の投稿・レスを直す。他人のものは断る(`{:error, :forbidden}`)。
  渡した欄だけ差し替える ── `status` は本文(`notes.content`)、`title` は
  根の投稿の題、`title_i18n`/`content_i18n` はもう一つの言語ぶん。

  連合に出ている(local_only でない)ものは `Notes.enqueue_update/1` で
  Update(Note) を配り直す ── フォロワー側の控えも新しくなる。
  """
  @spec update_post(Account.t() | integer(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | :forbidden | {:validation, map()}}
  def update_post(author, note_id, params) do
    account_id = id_of(author)

    case fetch_owned(to_int(note_id), account_id) do
      {:ok, {note, dn, account}} -> do_update(note, dn, account, stringify(params))
      {:error, _} = err -> err
    end
  end

  @doc """
  自分の投稿・レスを消す。他人のものは断る(`{:error, :forbidden}`)。
  `deco_notes` の行は外部キー(`on_delete: :delete_all`)で一緒に消える。
  federated Delete の配達は `Notes.delete_note/2` がそのまま持っている。
  """
  @spec delete_post(Account.t() | integer(), integer() | String.t()) ::
          :ok | {:error, :not_found | :forbidden}
  def delete_post(author, note_id) do
    with {:ok, {note, _dn, _account}} <- fetch_owned(to_int(note_id), id_of(author)),
         {:ok, _deleted} <- Notes.delete_note(note.account_id, note.id) do
      :ok
    end
  end

  @doc """
  気になった投稿・レスを、運営に知らせる。

  知らせは `reports` の行(`Moderation.create_report/1`)── sukhi の
  通報と同じ列に並び、運営は同じ画面で見る。板の口を別に持つのは、
  natadeco の画面が投稿しか知らないから(書いた人の id を配っていない)。
  相手はここで note から引く。

  同じ人が同じ投稿に二度言っても、行は一つ。自分の投稿には言えない
  (`{:error, :forbidden}`)── 消せる人が知らせる意味は無いので。

  返りは `{:ok, %{folded: boolean}}`。`@fold_after` 人からの知らせが
  開いたままなら、その投稿は読む側でたたまれる(`post_view` の
  `folded`)。ここで消したり隠したりはしない ── 決めるのは運営で、
  たたむのは決まるまでの手当て。
  """
  @spec report_post(Account.t() | integer(), integer() | String.t(), String.t() | nil) ::
          {:ok, %{folded: boolean()}} | {:error, :not_found | :forbidden}
  def report_post(reporter, note_id, comment \\ nil) do
    reporter_id = id_of(reporter)
    id = to_int(note_id)

    case Repo.get(Note, id) do
      nil ->
        {:error, :not_found}

      %Note{account_id: ^reporter_id} ->
        {:error, :forbidden}

      %Note{account_id: target_id} ->
        already? =
          Repo.exists?(
            from(r in Report,
              where: r.note_id == ^id and r.account_id == ^reporter_id and r.status == "open"
            )
          )

        result =
          if already?,
            do: {:ok, :already},
            else:
              Moderation.create_report(%{
                account_id: reporter_id,
                target_id: target_id,
                note_id: id,
                comment: comment || ""
              })

        case result do
          {:ok, _} -> {:ok, %{folded: id in folded_ids([id])}}
          {:error, cs} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
        end
    end
  end

  # この頁の投稿のうち、たたむ人数に届いているもの。note_id の列で一回引く。
  defp folded_ids([]), do: []

  defp folded_ids(note_ids) do
    from(r in Report,
      where: r.note_id in ^note_ids and r.status == "open",
      group_by: r.note_id,
      having: count(r.account_id, :distinct) >= @fold_after,
      select: r.note_id
    )
    |> Repo.all()
  end

  defp with_folded([]), do: []

  defp with_folded(views) do
    folded = MapSet.new(folded_ids(Enum.map(views, & &1.id)))
    Enum.map(views, fn v -> %{v | folded: MapSet.member?(folded, v.id)} end)
  end

  defp fetch_owned(id, account_id) do
    case Repo.one(
           from(dn in DecoNote,
             join: n in Note,
             on: n.id == dn.note_id,
             join: a in Account,
             on: a.id == n.account_id,
             where: dn.note_id == ^id,
             select: {n, dn, a}
           )
         ) do
      nil -> {:error, :not_found}
      {%Note{account_id: ^account_id} = n, dn, a} -> {:ok, {n, dn, a}}
      {%Note{}, _dn, _a} -> {:error, :forbidden}
    end
  end

  defp do_update(note, dn, account, params) do
    with :ok <- validate_title(params) do
      note_attrs = %{} |> maybe_put("content", params["status"]) |> maybe_put("title", params["title"])
      dn_attrs = Map.take(params, ["title_i18n", "content_i18n"])

      Repo.transaction(fn ->
        with {:ok, note} <- maybe_update(note, note_attrs),
             {:ok, dn} <- maybe_update(dn, dn_attrs) do
          {note, dn}
        else
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
      |> case do
        {:ok, {updated_note, updated_dn}} ->
          unless updated_dn.local_only, do: NotesCreate.enqueue_update(updated_note.id)
          {:ok, post_view(updated_note, updated_dn, account)}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
      end
    end
  end

  defp validate_title(%{"title" => t}) do
    if is_binary(t) and String.trim(t) != "", do: :ok, else: title_missing()
  end

  defp validate_title(_params), do: :ok

  defp maybe_update(struct, attrs) when map_size(attrs) == 0, do: {:ok, struct}
  defp maybe_update(%Note{} = note, attrs), do: note |> Note.changeset(attrs) |> Repo.update()
  defp maybe_update(%DecoNote{} = dn, attrs), do: dn |> DecoNote.changeset(attrs) |> Repo.update()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  # ── 読む ─────────────────────────────────────────────────────────────

  @doc """
  板の投稿（レスではない親だけ）を、動きのあった順に ── 新しいレスが
  付いた投稿が上に来る（レスの無い投稿は自分の投稿時刻のまま）。板の
  一覧が「名前順で競わせない」のとは別の話で、板の中では「いま話が
  動いているもの」が見えたほうがいい。

  `before_activity_at` + `before_id` の対で、そこより後ろから続きを
  取る ──「もっと読む」の道。片方だけでは並びが動く途中でずれる
  （新しいレスで順位が変わるので、note_id だけのカーソルは使えない）。
  """
  @spec list_posts(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def list_posts(slug, opts \\ []) do
    with {:ok, %{id: deco_id}} <- Boards.get_deco(slug) do
      limit = opts |> Keyword.get(:limit, 30) |> min(60) |> max(1)
      before_activity_at = opts[:before_activity_at]
      before_id = opts[:before_id]

      last_reply_at =
        from(r in Note,
          where: not is_nil(r.in_reply_to_ap_id) and r.visibility == "public",
          group_by: r.in_reply_to_ap_id,
          select: %{parent_ap_id: r.in_reply_to_ap_id, at: max(r.created_at)}
        )

      # 一段のクエリのまま(select と order_by/where で coalesce(...) を
      # 繰り返す)。%{note: n, ...} を subquery の select に置くと、
      # Ecto は構造体を subquery の map 値として許さない ── いったん
      # 別の subquery に包んでからだと弾かれる。
      q =
        from(dn in DecoNote,
          join: n in Note,
          on: n.id == dn.note_id,
          join: a in Account,
          on: a.id == n.account_id,
          left_join: la in subquery(last_reply_at),
          on: la.parent_ap_id == n.ap_id,
          where: dn.deco_id == ^deco_id and is_nil(n.in_reply_to_ap_id),
          order_by: [desc: coalesce(la.at, n.created_at), desc: n.id],
          limit: ^limit,
          select: {n, dn, a, coalesce(la.at, n.created_at)}
        )

      q =
        if before_activity_at && before_id do
          where(
            q,
            [dn, n, a, la],
            fragment(
              "(?, ?) < (?, ?)",
              coalesce(la.at, n.created_at),
              n.id,
              ^before_activity_at,
              ^to_int(before_id)
            )
          )
        else
          q
        end

      {:ok,
       Repo.all(q)
       |> Enum.map(fn {n, dn, a, at} ->
         Map.put(post_view(n, dn, a), :last_activity_at, to_utc(at))
       end)
       |> with_reactions(opts[:viewer_id])
       |> with_folded()}
    end
  end

  @doc """
  話す板の流れ。平らに、書かれた順（新しい順）。

  `list_posts/2` との違いは二つ ── 単位が投稿一件（スレッドではない）で、
  並びが最終返信ではなく `id`（＝時刻）。bump は「動いている話を上に
  留める」ための道具で、それは話題には優しく、雑談には重い。ここは
  留めずに流す。

  返信も同じ列に並ぶ。どこに向けた言葉かが消えないように、返信には
  親を一段だけ抱えさせる（`:parent`）── 祖父は辿らない。IRC の
  `nick:` が一段しか指さないのと同じ深さで、それで会話は追える。

  opts: `:limit`（既定 40・上限 100）/ `:before_id` / `:since_id` /
  `:since` / `:viewer_id`。

  `:since` は時刻（`DateTime`）で切りたいときの下限。「今日のぶんで
  終わる」は読む人の真夜中で切るので、境目を決めるのは読む人の時計に
  なる ── サーバは「今日」を知らない。id への変換はここでやる：
  snowflake の epoch はサーバの持ちものなので、フロントに配らない。
  """
  @spec list_flow(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def list_flow(slug, opts \\ []) do
    with {:ok, %{id: deco_id}} <- Boards.get_deco(slug) do
      limit = opts |> Keyword.get(:limit, 40) |> min(100) |> max(1)

      q =
        from(dn in DecoNote,
          join: n in Note,
          on: n.id == dn.note_id,
          join: a in Account,
          on: a.id == n.account_id,
          where: dn.deco_id == ^deco_id and n.visibility == "public",
          order_by: [desc: n.id],
          limit: ^limit,
          select: {n, dn, a}
        )

      q = if before_id = opts[:before_id], do: where(q, [dn, n], n.id < ^to_int(before_id)), else: q

      q =
        case since_bound(opts) do
          nil -> q
          since_id -> where(q, [dn, n], n.id >= ^since_id)
        end

      views =
        q
        |> Repo.all()
        |> Enum.map(fn {n, dn, a} -> post_view(n, dn, a) end)

      {:ok,
       views
       |> with_reactions(opts[:viewer_id])
       |> with_folded()
       |> with_parents()}
    end
  end

  # 下限。id で言われればそのまま、時刻で言われれば snowflake に直す。
  # 両方来たら id のほうが具体的なので、そちらを採る。
  defp since_bound(opts) do
    case {opts[:since_id], opts[:since]} do
      {nil, %DateTime{} = dt} -> Snowflake.encode(DateTime.to_unix(dt, :millisecond), 0)
      {nil, _} -> nil
      {id, _} -> to_int(id)
    end
  end

  # 返信が指している親を、この頁ぶんまとめて一度に添える。中身は
  # `SukhiFedi.Notes.Parents` ── 友デコ(Mastodon の home)も同じ形で
  # 親を抱えるので、道は一本にしてある。
  defp with_parents(views) do
    parents = Notes.parents_by_ap_id(Enum.map(views, & &1.in_reply_to_ap_id))

    Enum.map(views, fn v ->
      Map.put(v, :parent, v.in_reply_to_ap_id && Map.get(parents, v.in_reply_to_ap_id))
    end)
  end

  # `coalesce(la.at, n.created_at)` の型が subquery を跨ぐと Ecto に
  # :utc_datetime として伝わらず、NaiveDateTime で返ってくることがある
  # ── notes.created_at は常に UTC で入っているので、その前提で戻す。
  defp to_utc(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")
  defp to_utc(%DateTime{} = t), do: t

  @doc """
  投稿の本当の(AP の)ap_id。`/posts/:id` は人向けの見た目のいい URL
  で、連合が本当に見るべき場所(`/users/:name/notes/:id`)とは別 ──
  外から「返信」しようとした人が正しい場所に辿り着けるよう、
  `Accept: application/activity+json` で来た `/posts/:id` をここへ
  回す(router.ex)。公開の板の投稿だけ答える。
  """
  @spec ap_id_for_post(integer() | String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def ap_id_for_post(note_id) do
    id = to_int(note_id)

    result =
      Repo.one(
        from(dn in DecoNote,
          join: n in Note,
          on: n.id == dn.note_id,
          where: dn.note_id == ^id and n.visibility == "public",
          select: n
        )
      )

    case result && ap_id_of(result) do
      nil -> {:error, :not_found}
      ap_id -> {:ok, ap_id}
    end
  end

  @doc "一件と、そのレス（古い順 ── 掲示板は上から下へ読むので）。"
  @spec get_post(integer() | String.t(), integer() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def get_post(note_id, viewer_id \\ nil) do
    id = to_int(note_id)

    case Repo.one(
           from(dn in DecoNote,
             join: n in Note,
             on: n.id == dn.note_id,
             join: a in Account,
             on: a.id == n.account_id,
             where: dn.note_id == ^id,
             select: {n, dn, a}
           )
         ) do
      nil ->
        {:error, :not_found}

      {note, dn, author} ->
        # 本体と返信をひとつの列にしてから乗せる ── リアクションの
        # 問い合わせが、この頁ぜんぶで一回で済む。
        [post | replies] =
          [post_view(note, dn, author) | replies_of(note, dn.deco_id)]
          |> with_reactions(viewer_id)
          |> with_folded()

        {:ok, Map.put(post, :replies, replies)}
    end
  end

  # 連合越しの返信も、板の下に出す。「書いた道」は問わない ──
  # in_reply_to_ap_id が親を指していれば、それが素の Deco.reply/3 で
  # 書かれたものでも、他所のサーバーから普通に届いた返信(inbox 経由の
  # mirror、deco_notes の行は無い)でも、同じスレッドとして並べる。
  # 公開でないもの(フォロワー限定・DM)は板には出さない。
  defp replies_of(%Note{} = parent, deco_id) do
    case ap_id_of(parent) do
      nil ->
        []

      ap_id ->
        from(n in Note,
          left_join: dn in DecoNote,
          on: dn.note_id == n.id,
          join: a in Account,
          on: a.id == n.account_id,
          where: n.in_reply_to_ap_id == ^ap_id and n.visibility == "public",
          order_by: [asc: n.id],
          select: {n, dn, a}
        )
        |> Repo.all()
        |> Enum.map(fn {n, dn, a} -> post_view(n, dn, a, deco_id) end)
    end
  end

  # ── 形 ───────────────────────────────────────────────────────────────

  # `dn` は無いことがある ── 連合の返信は普通の inbox 経由で mirror
  # されるだけで、deco_notes の一行は付かない(deco_notes は
  # write/3 が板に書いたときだけ作る)。親と同じ板に属することは
  # in_reply_to_ap_id の一致だけで足りるので、行が無くても弾かない。
  # そのぶん `deco_id` は呼び出し側から親のを渡してもらう。
  # 親の公開範囲。連合越しに届いた親には deco_notes の行が無いので、
  # そのときは板の既定に落ちる(nil を返す)。
  defp parent_local_only(%Note{id: id}) do
    case Repo.get_by(DecoNote, note_id: id) do
      %DecoNote{local_only: v} -> v
      nil -> nil
    end
  end

  # その板の、公開範囲の既定。無い板は外に出る側（移行前の振る舞い）。
  defp put_audience(params, deco_id) do
    case Repo.one(from(d in Deco, where: d.id == ^deco_id, select: {d.slug, d.has_actor})) do
      {slug, true} -> Map.put(params, "audience", SukhiFedi.AP.GroupJson.actor_uri(slug))
      _ -> params
    end
  end

  defp truthy(v), do: v not in [nil, false, "false", 0, "0", ""]

  defp deco_local_default(deco_id) do
    Repo.one(from(d in Deco, where: d.id == ^deco_id, select: d.local_only)) || false
  end

  # 組み上がった view に、絵文字リアクションをまとめて乗せる。
  # `Notes.reactions_for_notes/2` は note_id の列で一回引くので、
  # `reply_count/1` のような一行ずつの問い合わせにはならない。
  #
  # 並びには使わない ── 反応は返事であって点数ではないので、
  # 数の多いものが上に行く形は持たない。
  defp with_reactions([], _viewer_id), do: []

  defp with_reactions(views, viewer_id) do
    by_id = Notes.reactions_for_notes(Enum.map(views, & &1.id), viewer_id)
    Enum.map(views, fn v -> %{v | reactions: Map.get(by_id, v.id, [])} end)
  end

  defp post_view(note, dn, author, fallback_deco_id \\ nil)

  defp post_view(%Note{} = n, %DecoNote{} = dn, %Account{} = author, _fallback) do
    %{
      id: n.id,
      deco_id: dn.deco_id,
      title: n.title,
      title_i18n: dn.title_i18n || %{},
      # 直すときの下書き欄に、いま書いてあるものをそのまま出すため
      # (HTML から Markdown は戻せない)。ローカルの投稿は notes.content
      # がエスケープ済みの生 Markdown なので戻す ── 連合越しの mirror は
      # 元から HTML そのものなので触らない(自分の投稿として直せることも
      # 無い)。
      content: raw_content(n),
      content_i18n: dn.content_i18n || %{},
      content_html: Note.html(n),
      content_html_i18n: render_i18n_html(dn.content_i18n),
      emojis: n.emojis || [],
      author: View.author(author),
      created_at: n.created_at,
      reply_count: reply_count(n),
      # 誰に向けた言葉か。話す板の流れで親を抱えるときの鍵になる。
      in_reply_to_ap_id: n.in_reply_to_ap_id,
      # 既定は空。読む口(`list_posts/2`・`get_post/2`)は `with_reactions/2`
      # でここを上書きする ── 書いたばかりの投稿は本当に空なので、
      # 書く口はそのままでいい。
      reactions: [],
      local_only: dn.local_only || false,
      as_article: dn.as_article || false,
      # 既定は開いたまま。読む口が `with_folded/1` で上書きする。
      folded: false
    }
  end

  defp post_view(%Note{} = n, nil, %Account{} = author, fallback_deco_id) do
    %{
      id: n.id,
      deco_id: fallback_deco_id,
      title: n.title,
      title_i18n: %{},
      content: raw_content(n),
      content_i18n: %{},
      content_html: Note.html(n),
      content_html_i18n: %{},
      emojis: n.emojis || [],
      author: View.author(author),
      created_at: n.created_at,
      reply_count: reply_count(n),
      in_reply_to_ap_id: n.in_reply_to_ap_id,
      reactions: [],
      local_only: false,
      as_article: false,
      folded: false
    }
  end

  defp raw_content(%Note{domain: nil, content: content}), do: SukhiFedi.HTML.unescape(content)
  defp raw_content(%Note{content: content}), do: content

  # content_i18n は生の Markdown(notes.content と同じ形)。読むときだけ
  # HTML 化する ── 書くときに二重に持たせない。
  defp render_i18n_html(nil), do: %{}

  defp render_i18n_html(map) when is_map(map) do
    Map.new(map, fn {lang, text} -> {lang, SukhiFedi.Markdown.to_html(text)} end)
  end

  # 板の上に出る「その人」。表示名だけだと同じ名前が並んだときに見分け
  # がつかないので、`acct`（ハンドル）も一緒に返す ── どちらを大きく
  # 出すかは、見せる側で決められるように。
  # replies_of/2 と同じ範囲(deco_notes の有無を問わない、公開のみ)。
  defp reply_count(%Note{} = n) do
    case ap_id_of(n) do
      nil ->
        0

      ap_id ->
        Repo.one(
          from(r in Note,
            where: r.in_reply_to_ap_id == ^ap_id and r.visibility == "public",
            select: count(r.id)
          )
        ) || 0
    end
  end

  # 作りたてを返すとき、`notes.ap_id` はまだ載っていないことがある
  # （Notes 側が insert のあとに別の段で焼くので、返ってくる構造体は
  # 焼く前の姿）。ぶら下がりを数える相手は、その ap_id なので、
  # 手元で組み直しておく ── 「レス0件」に見えてしまうため。
  defp ap_id_of(%Note{ap_id: ap_id}) when is_binary(ap_id), do: ap_id
  defp ap_id_of(%Note{id: id}) when is_integer(id), do: Ids.note_ap_id(id)
  defp ap_id_of(_), do: nil

  # ap_id があればそれを渡す ── bare id だと resolve_in_reply_to_ap_id/1
  # が「ローカルの note」と決め打ちして合成してしまい、連合越しの
  # mirror(レス先が実は他所の投稿)を取り違える。ap_id なら、それが
  # 自分のドメインの URL でも NoteFetcher.fetch_and_mirror/1 が
  # notes.ap_id を先に引くので、余計な fetch にはならない。
  defp parent_ref(%Note{ap_id: ap_id}) when is_binary(ap_id), do: ap_id
  defp parent_ref(%Note{id: id}), do: id

  # 呼び出し側は Account を持っていたり、id だけ持っていたりする
  # （`Notes.favourite/2` などの兄弟と同じ受け方に揃えてある）。
  defp id_of(%Account{id: id}), do: id
  defp id_of(id) when is_integer(id), do: id

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end

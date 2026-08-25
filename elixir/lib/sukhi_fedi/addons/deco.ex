# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Deco do
  @moduledoc """
  Deco addon — natadeco の掲示板。板一枚が「デコ」で、投稿は既存の
  `notes` に相乗りする（`deco_notes` は「どの板か」だけを持つ）。

  書いた人は隠さない。note.com と同じで、板の上でもその人の名前と
  ハンドルがそのまま出る ── 名前のうしろに立てば、書いたものは自分の
  ものになる。

  ここが持つのは器だけ。本文・HTML 化・タグ・メディア・削除は
  `SukhiFedi.Notes` のまま ── 同じものの道を二本作らないため。

  板は Group actor(`{slug}-deco@domain`)を持てる ── 個人アカウントの
  username はハイフンを使えないので、この形は名前空間が構造的に
  ぶつからない。actor JSON は `SukhiFedi.AP.GroupJson` が組む。
  いまは actor が引ける・webfinger で見つかるところまで(フォローの
  受理・Announce 中継はまだ先の段)。表札(`has_actor`)を出さない板は
  鍵を持たず、`get_actor_record/1` が `:not_found` を返す。

  ## 読むのは、いつでも誰でも

  `local_only` も `has_actor` も、決めているのは **どこまで届くか** で
  あって、**誰が読めるか** ではない。前者は書いたものが外の網に出るか、
  後者は場が外から見つかるか。どちらが false でも、natadeco に来た人が
  読めるものは変わらない ── 読む口(`list_decos/0`・`list_posts/2`・
  `get_post/2`)はトークンを要らないし、viewer で絞りもしない。
  `viewer_id` を受けるのは反応の `me` を立てるためだけで、見えるものの
  数は viewer で変わらない。

  完全に閉じた板は、作れない構造にしてある。鍵をかけたくなったときは、
  それは掲示板ではない別のものを作っている ── あたたかいものは、
  隠さなくていいので。

  この約束は `test/integration/deco_test.exs` の「隠れた板は作れない」
  で留めてある。ここに viewer の絞りを足すと、あそこが落ちる。
  """

  use SukhiFedi.Addon, id: :deco

  import Ecto.Query

  alias SukhiFedi.{Notes, Notifications, Repo}
  alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen
  alias SukhiFedi.Notes.Create, as: NotesCreate
  alias SukhiFedi.Notes.Ids
  alias SukhiFedi.Schema.{Account, Deco, DecoNote, Note}

  # ── 板 ───────────────────────────────────────────────────────────────

  @doc "板の一覧。新しい順ではなく、名前順 ── 数で競わせないため。"
  @spec list_decos() :: [map()]
  def list_decos do
    counts =
      from(dn in DecoNote, group_by: dn.deco_id, select: {dn.deco_id, count(dn.id)})
      |> Repo.all()
      |> Map.new()

    from(d in Deco, order_by: [asc: d.name])
    |> Repo.all()
    |> Enum.map(&view(&1, Map.get(counts, &1.id, 0)))
  end

  @spec get_deco(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_deco(slug) when is_binary(slug) do
    case Repo.get_by(Deco, slug: String.downcase(String.trim(slug))) do
      nil -> {:error, :not_found}
      %Deco{} = d -> {:ok, view(d, count_posts(d.id))}
    end
  end

  # 作るときの指定。既定は表札あり ── いままでの板がそうなので。
  defp has_actor?(attrs) do
    case Map.get(attrs, "has_actor") do
      nil -> true
      v -> v not in [false, "false", 0, "0"]
    end
  end

  defp generated_keys do
    keys = KeyGen.generate()

    %{
      "public_key_pem" => keys.public_pem,
      "public_key_jwk" => keys.public_jwk,
      "private_key_jwk" => keys.private_jwk,
      "ed25519_private_key_jwk" => keys.ed25519_private_jwk,
      "ed25519_public_multibase" => keys.ed25519_public_multibase
    }
  end

  @doc """
  外から引ける板だけを返す ── 表札を出していない板は、連合の側から
  見れば「そこには何も無い」。存在まで漏らさないよう `:not_found` で
  揃える(`get_deco_record/1` は中の道なので、そちらは素通し)。
  """
  @spec get_actor_record(String.t()) :: {:ok, Deco.t()} | {:error, :not_found}
  def get_actor_record(slug) when is_binary(slug) do
    case get_deco_record(slug) do
      {:ok, %Deco{has_actor: true} = d} -> {:ok, d}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  素の `%Deco{}`(鍵込み)を返す ── `get_deco/1` は API 向けの view に
  削っているので、actor JSON を組むにはこちらを使う。
  """
  @spec get_deco_record(String.t()) :: {:ok, Deco.t()} | {:error, :not_found}
  def get_deco_record(slug) when is_binary(slug) do
    case Repo.get_by(Deco, slug: String.downcase(String.trim(slug))) do
      nil -> {:error, :not_found}
      %Deco{} = d -> {:ok, d}
    end
  end

  @spec create_deco(Account.t() | integer(), map()) ::
          {:ok, map()} | {:error, {:validation, map()}}
  def create_deco(%Account{id: aid}, attrs), do: create_deco(aid, attrs)

  def create_deco(account_id, attrs) when is_integer(account_id) do
    attrs = stringify(attrs)

    # 鍵は表札のある板だけが持つ。表札を出さない板は actor として
    # 立たないので、署名する立場そのものが無い ── 使わない秘密鍵を
    # 置いておかない。
    key_attrs = if has_actor?(attrs), do: generated_keys(), else: %{}

    %Deco{}
    |> Deco.changeset(
      attrs
      |> Map.put("created_by_id", account_id)
      |> Map.merge(key_attrs)
    )
    |> Repo.insert()
    |> case do
      {:ok, d} -> {:ok, view(d, 0)}
      {:error, cs} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
    end
  end

  @doc """
  板ごと畳む。中の投稿も本当に消す(`deco_notes` は cascade で消えるが、
  中身の `notes` はそれだけでは残ってしまうので、一件ずつ
  `delete_note_for_cleanup/3` で ── 誰が書いたかに関わらず消せる、
  federated Delete も出す片づけ用の道)。取り消せない。
  """
  @spec delete_deco(String.t()) :: :ok | {:error, :not_found}
  def delete_deco(slug) when is_binary(slug) do
    case Repo.get_by(Deco, slug: String.downcase(String.trim(slug))) do
      nil ->
        {:error, :not_found}

      %Deco{} = d ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(dn in DecoNote, where: dn.deco_id == ^d.id, select: dn.note_id)
        |> Repo.all()
        |> Enum.each(fn note_id ->
          case Repo.get(Note, note_id) do
            nil -> :ok
            %Note{} = note -> NotesCreate.delete_note_for_cleanup(note, now, "board removed")
          end
        end)

        Repo.delete(d)
        :ok
    end
  end

  # ── 書く ─────────────────────────────────────────────────────────────

  @doc """
  板に一件書く。`params` は `%{"title" => _, "status" => _}`。板の一覧に
  並ぶのは題だけなので、無題だと一覧の上で見分けがつかない ── title は必須。
  返りは `list_posts/2` と同じ形。
  """
  @spec post(Account.t() | integer(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | atom() | {:validation, map()}}
  def post(author, slug, params) do
    with {:ok, %{id: deco_id, kind: kind}} <- get_deco(slug),
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
  defp deco_id_for_thread(note), do: deco_id_for_thread(note, @max_thread_walk)
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
    local_only? =
      case {Map.get(rest, "visibility"), default_local} do
        {"local", _} -> true
        {"public", _} -> false
        {_, nil} -> deco_local_default(deco_id)
        {_, inherited} -> inherited
      end
    note_params = Map.put(rest, "local_only", local_only?)

    with :ok <- check_pace(account_id) do
      # note を先に作り、そのあと板に結ぶ。note づくりは Notes 側の
      # トランザクション（outbox 込み）なので、こちらでは包めない。
      # 結びに失敗したら note は消す ── どこにも属さない投稿を残さない。
      case Notes.create_status(account_id, Map.put(note_params, "visibility", "public")) do
        {:ok, note} ->
          %DecoNote{}
          |> DecoNote.changeset(
            Map.merge(%{"deco_id" => deco_id, "note_id" => note.id, "local_only" => local_only?}, i18n)
          )
          |> Repo.insert()
          |> case do
            {:ok, dn} ->
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
    with {:ok, %{id: deco_id}} <- get_deco(slug) do
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
       |> with_reactions(opts[:viewer_id])}
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
  `:viewer_id`。`:since_id` は「今日のぶんで終わる」のための下限で、
  読む人の真夜中から作った id を渡す。
  """
  @spec list_flow(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def list_flow(slug, opts \\ []) do
    with {:ok, %{id: deco_id}} <- get_deco(slug) do
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
      q = if since_id = opts[:since_id], do: where(q, [dn, n], n.id >= ^to_int(since_id)), else: q

      views =
        q
        |> Repo.all()
        |> Enum.map(fn {n, dn, a} -> post_view(n, dn, a) end)

      {:ok,
       views
       |> with_reactions(opts[:viewer_id])
       |> with_parents()}
    end
  end

  # 返信が指している親を、この頁ぶんまとめて一度に引く。行ごとに
  # 引くと、頁の長さだけ問い合わせが増える。
  #
  # 抱えるのは「誰に向けた言葉か」が分かるぶんだけ ── 本文をもう一度
  # 積むと、同じものが二度並ぶ。連合越しの親など手元に無いものは
  # `nil` のまま（「返信」とだけ出る）。
  defp with_parents(views) do
    parent_ap_ids =
      views |> Enum.map(& &1.in_reply_to_ap_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    parents =
      if parent_ap_ids == [] do
        %{}
      else
        from(n in Note,
          join: a in Account,
          on: a.id == n.account_id,
          where: n.ap_id in ^parent_ap_ids,
          select: {n.ap_id, n, a}
        )
        |> Repo.all()
        |> Map.new(fn {ap_id, n, a} ->
          {ap_id, %{id: n.id, author: author_view(a), excerpt: excerpt(n)}}
        end)
      end

    Enum.map(views, fn v ->
      Map.put(v, :parent, v.in_reply_to_ap_id && Map.get(parents, v.in_reply_to_ap_id))
    end)
  end

  @excerpt_len 80

  # 親を思い出すぶんの一行。HTML を剥いで、一行に畳んで、切る。
  defp excerpt(%Note{} = n) do
    n
    |> Note.html()
    |> String.replace(~r{<[^>]*>}, "")
    |> String.replace(~r{\s+}, " ")
    |> String.trim()
    |> String.slice(0, @excerpt_len)
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
          with_reactions(
            [post_view(note, dn, author) | replies_of(note, dn.deco_id)],
            viewer_id
          )

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

  defp view(%Deco{} = d, post_count) do
    %{
      id: d.id,
      slug: d.slug,
      name: d.name,
      name_i18n: d.name_i18n || %{},
      description: d.description,
      description_i18n: d.description_i18n || %{},
      local_only: d.local_only || false,
      has_actor: d.has_actor,
      kind: d.kind || "thread",
      post_count: post_count,
      created_at: d.created_at
    }
  end

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
      author: author_view(author),
      created_at: n.created_at,
      reply_count: reply_count(n),
      # 誰に向けた言葉か。話す板の流れで親を抱えるときの鍵になる。
      in_reply_to_ap_id: n.in_reply_to_ap_id,
      # 既定は空。読む口(`list_posts/2`・`get_post/2`)は `with_reactions/2`
      # でここを上書きする ── 書いたばかりの投稿は本当に空なので、
      # 書く口はそのままでいい。
      reactions: [],
      local_only: dn.local_only || false
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
      author: author_view(author),
      created_at: n.created_at,
      reply_count: reply_count(n),
      in_reply_to_ap_id: n.in_reply_to_ap_id,
      reactions: [],
      local_only: false
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
  defp author_view(%Account{} = a) do
    %{
      username: a.username,
      acct: if(a.domain, do: "#{a.username}@#{a.domain}", else: a.username),
      display_name: a.display_name || a.username,
      avatar_url: a.avatar_url
    }
  end

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

  defp count_posts(deco_id) do
    Repo.one(from(dn in DecoNote, where: dn.deco_id == ^deco_id, select: count(dn.id))) || 0
  end

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

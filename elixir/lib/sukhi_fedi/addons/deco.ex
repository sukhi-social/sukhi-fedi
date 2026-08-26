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

  alias SukhiFedi.{Notes, Notifications, Outbox, Repo, Snowflake}
  alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen
  alias SukhiFedi.Notes.Create, as: NotesCreate
  alias SukhiFedi.Federation.CollectionFetcher
  alias SukhiFedi.Notes.Ids
  alias SukhiFedi.Schema.{Account, Deco, DecoFollower, DecoNote, DecoPref, Note}

  # ── 板 ───────────────────────────────────────────────────────────────

  @doc """
  板の一覧。新しい順ではなく、名前順 ── 数で競わせないため。

  読む人が居れば、一枚ごとに「気にかけているか(`minding`)」「最後に
  見たあとに動きがあったか(`unread`)」「知らせかた(`notify`)」が付く。
  気にかけているかは**書いたことがあるか**から出る ── 押して宣言する
  ものではない。

  **並びは変えない** ── 気にかけているぶんを上へ寄せるのは読む側の
  仕事で、その中も外も名前順のまま。活動量で並べ替えないのは、板一覧を
  作ったときの決めごとで、ここに未読を足しても変わらない。
  """
  @spec list_decos(integer() | nil) :: [map()]
  def list_decos(viewer_id \\ nil) do
    counts =
      from(dn in DecoNote, group_by: dn.deco_id, select: {dn.deco_id, count(dn.id)})
      |> Repo.all()
      |> Map.new()

    decos = from(d in Deco, order_by: [asc: d.name]) |> Repo.all()
    marks = viewer_marks(viewer_id, Enum.map(decos, & &1.id))

    Enum.map(decos, fn d ->
      d
      |> view(Map.get(counts, d.id, 0))
      |> Map.merge(Map.get(marks, d.id, %{minding: false, unread: false, notify: "participating"}))
    end)
  end

  # 読む人ごとの印。
  #
  # 「入る」ボタンは無い ── 自分が書いた板は、書いた時点で自分の場所に
  # なっている（宣言ではなく事実）。押させる代わりに、もうやったことを
  # 見ている。読んでいるだけの板をどう扱うかは、その板を開いたときの
  # 詳細設定で決める。
  #
  #   participating — 既定。自分が書いた板だけ気にかける
  #   all           — 読んでいるだけでも気にかける
  #   quiet         — 光らない
  defp viewer_marks(nil, _deco_ids), do: %{}
  defp viewer_marks(_viewer_id, []), do: %{}

  defp viewer_marks(viewer_id, deco_ids) do
    prefs =
      from(p in DecoPref,
        where: p.account_id == ^viewer_id and p.deco_id in ^deco_ids,
        select: {p.deco_id, {p.seen_at, p.notify}}
      )
      |> Repo.all()
      |> Map.new()

    wrote = wrote_in(viewer_id, deco_ids)
    minding = Enum.filter(deco_ids, &minding?(&1, wrote, prefs))
    last = last_activity(minding)

    Map.new(deco_ids, fn id ->
      seen_at = prefs |> Map.get(id, {nil, nil}) |> elem(0)
      mind? = id in minding

      unread? =
        mind? and
          case {Map.get(last, id), seen_at} do
            {nil, _} -> false
            {_at, nil} -> true
            {at, seen} -> DateTime.compare(at, seen) == :gt
          end

      {id, %{minding: mind?, unread: unread?, notify: notify_of(id, prefs)}}
    end)
  end

  defp notify_of(id, prefs) do
    case Map.get(prefs, id) do
      {_seen, n} when is_binary(n) -> n
      _ -> "participating"
    end
  end

  defp minding?(id, wrote, prefs) do
    case notify_of(id, prefs) do
      "quiet" -> false
      "all" -> true
      _ -> MapSet.member?(wrote, id)
    end
  end

  # 書いたことがある板。参加が、そのまま「自分の場所」になる。
  defp wrote_in(viewer_id, deco_ids) do
    from(dn in DecoNote,
      join: n in Note,
      on: n.id == dn.note_id,
      where: dn.deco_id in ^deco_ids and n.account_id == ^viewer_id,
      distinct: true,
      select: dn.deco_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # 板の最後の動き。返信も数える ── 誰かが答えたのも「動いた」なので。
  defp last_activity([]), do: %{}

  defp last_activity(deco_ids) do
    from(dn in DecoNote,
      join: n in Note,
      on: n.id == dn.note_id,
      where: dn.deco_id in ^deco_ids and n.visibility == "public",
      group_by: dn.deco_id,
      select: {dn.deco_id, max(n.created_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  いま話していること（IRC の /topic）。

  変えられるのは **その板に書いたことがある人と、立てた人**。通りすがり
  は変えられないが、立てた人だけにもしない ── 立てた人だけの持ちものに
  すると、三年前のまま誰も直せない一行になる。IRC でいう「居る人」に
  あたるのが、natadeco では「書いたことがある人」。

  誰が・いつ を一緒に残す。板の顔になる一行を黙って書き換えられる形に
  はしない ──「書いた人は隠さない」と同じ理由で、それ自体が抑止になる。
  """
  @spec set_topic(Account.t() | integer(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found | :forbidden | {:validation, map()}}
  def set_topic(account, slug, topic) do
    aid = id_of(account)

    with {:ok, %Deco{} = d} <- get_deco_record(slug),
         :ok <- may_set_topic?(aid, d) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      trimmed = topic && String.trim(topic)
      cleared? = trimmed in [nil, ""]

      d
      |> Deco.changeset(%{
        "topic" => if(cleared?, do: nil, else: trimmed),
        "topic_by_id" => if(cleared?, do: nil, else: aid),
        "topic_at" => if(cleared?, do: nil, else: now)
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, view(updated, count_posts(updated.id))}
        {:error, cs} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
      end
    end
  end

  defp may_set_topic?(account_id, %Deco{id: deco_id, created_by_id: owner}) do
    cond do
      account_id == owner -> :ok
      MapSet.member?(wrote_in(account_id, [deco_id]), deco_id) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp topic_by(%Deco{topic_by_id: nil}), do: nil

  defp topic_by(%Deco{topic_by_id: id}) do
    case Repo.get(Account, id) do
      %Account{} = a -> author_view(a)
      nil -> nil
    end
  end

  @doc """
  この板の知らせかたを決める。板の中の詳細設定から来る。

  一覧にボタンを置かないのは、押させる動作にするほどのものではない
  から ── 既定のままで困らない人がほとんどで、ずらしたい人はその板を
  開いたときに決めればいい。
  """
  @spec set_notify(Account.t() | integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :bad_notify}
  def set_notify(account, slug, notify) do
    if notify in DecoPref.notify_kinds() do
      with {:ok, %{id: deco_id}} <- get_deco(slug) do
        upsert_pref(id_of(account), deco_id, %{"notify" => notify})
        {:ok, %{notify: notify}}
      end
    else
      {:error, :bad_notify}
    end
  end

  @doc "その板を、いま見た。板を開いたときに呼ぶ ── 光りが消える。"
  @spec seen(Account.t() | integer(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def seen(account, slug) do
    with {:ok, %{id: deco_id}} <- get_deco(slug) do
      upsert_pref(id_of(account), deco_id, %{})
      {:ok, %{seen: true}}
    end
  end

  # 読んだ位置は、触るたび「いま」に進む。知らせかたは渡されたときだけ
  # 変える ── 設定を変えただけで、読んだことにはしない。
  #
  # 行がまだ無いときも同じ。`on_conflict` は既にある行にしか効かないので、
  # 知らせかただけを変える呼びに `seen_at` を入れると、その一件目が
  # 「いま読んだ」になってしまう（実際に一度そうなった）。
  defp upsert_pref(account_id, deco_id, extra) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reading? = not Map.has_key?(extra, "notify")
    set = if reading?, do: [seen_at: now], else: [notify: extra["notify"]]
    base = %{"account_id" => account_id, "deco_id" => deco_id}
    base = if reading?, do: Map.put(base, "seen_at", now), else: base

    %DecoPref{}
    |> DecoPref.changeset(Map.merge(base, extra))
    |> Repo.insert(on_conflict: [set: set], conflict_target: [:account_id, :deco_id])
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
              announce_new_post(deco_id, note.id)

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
  `:since` / `:viewer_id`。

  `:since` は時刻（`DateTime`）で切りたいときの下限。「今日のぶんで
  終わる」は読む人の真夜中で切るので、境目を決めるのは読む人の時計に
  なる ── サーバは「今日」を知らない。id への変換はここでやる：
  snowflake の epoch はサーバの持ちものなので、フロントに配らない。
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
      topic: d.topic,
      topic_by: topic_by(d),
      topic_at: d.topic_at,
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
  defp put_audience(params, deco_id) do
    case Repo.one(from(d in Deco, where: d.id == ^deco_id, select: {d.slug, d.has_actor})) do
      {slug, true} -> Map.put(params, "audience", SukhiFedi.AP.GroupJson.actor_uri(slug))
      _ -> params
    end
  end

  # ── ベランダ（外の板を見に行く） ─────────────────────────────

  @doc """
  よその板を覗く。追う前に、どんな場所か見るための口。

  引くだけで、**何も残さない** ── `notes` にも `accounts` にも書かない。
  だから通報も削除もこちらではできないし、できないのが正しい。ここに
  出ているのはよそのおうちの話で、natadeco が載せているものではない。
  それが手すり。

  相手の Group actor(`{slug}@host` の形か、actor URI そのもの)を引いて、
  その outbox を読む。Lemmy / PieFed / NodeBB はどれも
  `Announce(Create(Page|Note))` を本文ごと並べているので、一度引けば
  開き手が丸ごと手に入る。

  **開き手しか取れない相手がいる。** Lemmy 0.19 の板の outbox には
  コメントが一件も入っていない(数えた)。会話の中まで読むには相手が
  `context`(FEP-7888)を出している必要があり、それは PieFed と NodeBB
  だけ。取れないものは取れないまま出す ── 「全部見えている」ふりを
  しない。
  """
  @spec peek(String.t()) :: {:ok, map()} | {:error, term()}
  def peek(handle_or_uri) when is_binary(handle_or_uri) do
    with {:ok, actor} <- fetch_remote_actor(handle_or_uri),
         outbox when is_binary(outbox) <- actor["outbox"],
         {:ok, items, meta} <-
           CollectionFetcher.fetch(outbox, sign_as: SukhiFedi.Accounts.signing_identity()) do
      {:ok,
       %{
         actor: remote_actor_view(actor),
         posts: items |> Enum.map(&remote_post_view/1) |> Enum.reject(&is_nil/1),
         truncated: meta.truncated
       }}
    else
      nil -> {:error, :no_outbox}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp fetch_remote_actor("http" <> _ = uri), do: SukhiFedi.Federation.ActorFetcher.fetch(uri)

  defp fetch_remote_actor(handle) do
    case SukhiFedi.Federation.WebFinger.resolve_self(handle) do
      {:ok, uri} when is_binary(uri) -> SukhiFedi.Federation.ActorFetcher.fetch(uri)
      _ -> {:error, :not_found}
    end
  end

  defp remote_actor_view(a) do
    %{
      id: a["id"],
      name: a["name"] || a["preferredUsername"],
      handle: a["preferredUsername"],
      summary: a["summary"],
      url: a["url"] || a["id"],
      icon: get_in(a, ["icon", "url"]),
      type: a["type"]
    }
  end

  # `Announce(Create(Page|Note))` も、素の `Create` も、剥いた本体も来る。
  # 本文の在るものだけを拾って、無いものは黙って落とす。
  defp remote_post_view(%{"object" => inner}) when is_map(inner), do: remote_post_view(inner)

  defp remote_post_view(%{"type" => t} = o) when t in ["Page", "Note", "Article", "Question"] do
    %{
      id: o["id"],
      url: o["url"] || o["id"],
      title: o["name"],
      content_html: o["content"],
      author: o["attributedTo"],
      published: o["published"]
    }
  end

  defp remote_post_view(_), do: nil

  # ── 板を追う人（外から） ─────────────────────────────────────

  @doc """
  板が、新しく立った話を追っている相手に配る（FEP-1b12 の `Announce`）。

  **開き手だけ。返信は流さない。** 板を追うと会話の一言ずつが流れて
  くる形にはしない ── 追った人の面に流れるのは「ここで新しい話が
  立った」だけでいい。Lemmy の板の outbox も、数えると開き手しか
  入っていない。

  形は `Announce(<note の URI>)`。FEP-1b12 は `Announce(Create(…))` を
  本筋と書いているが、Mastodon の Announce は object が**オブジェクト
  である前提**で組まれていて、中身がアクティビティだと弾かれる
  (`status_from_object` が nil になる)。掲示板を持つ実装は URI を
  引きに来て、そこで `audience` を見つけられる ── 一つの形で両方に
  届くほうを採った。

  `local_only` の投稿は配らない。表札の無い板は追われようがない。
  """
  @spec announce_new_post(integer(), integer()) :: :ok
  def announce_new_post(deco_id, note_id) when is_integer(deco_id) and is_integer(note_id) do
    with %Note{} = note <- Repo.get(Note, note_id),
         true <- is_nil(note.in_reply_to_ap_id),
         %DecoNote{local_only: false} <- Repo.get_by(DecoNote, note_id: note_id),
         {slug, true} <-
           Repo.one(from(d in Deco, where: d.id == ^deco_id, select: {d.slug, d.has_actor})),
         [_ | _] = inboxes <- follower_inboxes(deco_id),
         %Account{username: username} <- Repo.get(Account, note.account_id) do
      actor = SukhiFedi.AP.GroupJson.actor_uri(slug)
      object = SukhiFedi.Notes.Ids.note_ap_id(note_id) || local_note_uri(username, note_id)

      Outbox.enqueue("sns.outbox.announce.created", "deco", deco_id, %{
        deco_actor: actor,
        object: object,
        activity_id: "#{actor}/announces/#{note_id}",
        inboxes: inboxes
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp local_note_uri(username, note_id),
    do: "https://#{SukhiFedi.Config.domain!()}/users/#{username}/notes/#{note_id}"

  @doc """
  板への `Follow` を控える。`manuallyApprovesFollowers` は false と
  名乗っているので、受けた時点で通っている ── 待たせる状態は持たない。

  板の actor URI(`{slug}-deco`)で受け取る。表札を出していない板は
  そもそも引けないので、ここには来ない。
  """
  @spec record_follow(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def record_follow(deco_actor_uri, follower_uri, inbox_url) do
    case deco_id_from_audience(deco_actor_uri) do
      nil ->
        {:error, :not_found}

      deco_id ->
        %DecoFollower{}
        |> DecoFollower.changeset(%{
          "deco_id" => deco_id,
          "follower_uri" => follower_uri,
          "inbox_url" => inbox_url
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:deco_id, :follower_uri])

        :ok
    end
  end

  @doc "板を追うのをやめた人を落とす（`Undo(Follow)`）。"
  @spec drop_follow(String.t(), String.t()) :: :ok
  def drop_follow(deco_actor_uri, follower_uri) do
    case deco_id_from_audience(deco_actor_uri) do
      nil ->
        :ok

      deco_id ->
        from(f in DecoFollower,
          where: f.deco_id == ^deco_id and f.follower_uri == ^follower_uri
        )
        |> Repo.delete_all()

        :ok
    end
  end

  @doc "その板を追っている相手の inbox。Announce の配り先。"
  @spec follower_inboxes(integer()) :: [String.t()]
  def follower_inboxes(deco_id) when is_integer(deco_id) do
    from(f in DecoFollower,
      where: f.deco_id == ^deco_id and not is_nil(f.inbox_url),
      select: f.inbox_url,
      distinct: true
    )
    |> Repo.all()
  end

  @doc "板を追っている相手の actor URI（followers コレクション用）。"
  @spec follower_uris(String.t()) :: {:ok, [String.t()]} | {:error, :not_found}
  def follower_uris(slug) when is_binary(slug) do
    with {:ok, %Deco{id: id}} <- get_actor_record(slug) do
      {:ok,
       from(f in DecoFollower, where: f.deco_id == ^id, select: f.follower_uri, order_by: f.id)
       |> Repo.all()}
    end
  end

  @doc """
  この一件が、線の上で名乗るぶん ── どの板のものか(`audience`)と、
  長い文章として出すか(`as_article`)。

  引かれる側(`Web.NoteController`)が使う。配るほうは outbox の payload
  に載って行くが、GET は note 行しか手元に無いので、ここで訊く。
  板に属さない note は両方 nil/false。
  """
  @spec wire_info(integer()) :: %{audience: String.t() | nil, as_article: boolean()}
  def wire_info(note_id) when is_integer(note_id) do
    case Repo.one(
           from(dn in DecoNote,
             join: d in Deco,
             on: d.id == dn.deco_id,
             where: dn.note_id == ^note_id,
             select: {d.slug, d.has_actor, dn.as_article}
           )
         ) do
      {slug, true, article?} ->
        %{audience: SukhiFedi.AP.GroupJson.actor_uri(slug), as_article: !!article?}

      {_slug, _no_actor, article?} ->
        %{audience: nil, as_article: !!article?}

      nil ->
        %{audience: nil, as_article: false}
    end
  end

  @doc """
  外から届いた一件を、板に結ぶ。

  結んでおかないと、板の一覧にも流れにも出てこない ── どちらも
  `deco_notes` を join するので。読むたびに親を遡って板を探すことも
  できるが、それは頁を開くたびに払う値段になる。書き込みの一度で済む。

  どの板かは二段で決める:

    1. `audience`(FEP-1b12) ── 掲示板を持つ実装は自分で名乗ってくれる
    2. 名乗らない相手(Mastodon など)は、返信先を遡って探す

  結べなかったものは、そのまま置く。板の外の会話として普通に流れる。
  """
  @spec bind_inbound(integer(), map()) :: :ok
  def bind_inbound(note_id, raw) when is_integer(note_id) and is_map(raw) do
    with %Note{} = note <- Repo.get(Note, note_id),
         deco_id when is_integer(deco_id) <- inbound_deco_id(note, raw) do
      %DecoNote{}
      |> DecoNote.changeset(%{"deco_id" => deco_id, "note_id" => note_id})
      |> Repo.insert(on_conflict: :nothing, conflict_target: :note_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp inbound_deco_id(%Note{} = note, raw) do
    case deco_id_from_audience(raw["audience"]) do
      nil -> deco_id_for_thread(note)
      id -> id
    end
  end

  # `{slug}-deco` の actor URI から板を引く。他所の板の audience は
  # ここで外れる（自分の domain の形にしか合わないので）。
  # actor URI から板を引く。`audience` と Follow の宛先が同じ形なので
  # 一本で足りる。
  defp deco_id_from_audience(uri) when is_binary(uri) do
    prefix = "https://#{SukhiFedi.Config.domain!()}/users/"

    with true <- String.starts_with?(uri, prefix),
         name <- String.trim_leading(uri, prefix),
         true <- String.ends_with?(name, "-deco"),
         slug <- String.trim_trailing(name, "-deco"),
         %Deco{id: id} <- Repo.get_by(Deco, slug: slug) do
      id
    else
      _ -> nil
    end
  end

  defp deco_id_from_audience(_), do: nil

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
      author: author_view(author),
      created_at: n.created_at,
      reply_count: reply_count(n),
      # 誰に向けた言葉か。話す板の流れで親を抱えるときの鍵になる。
      in_reply_to_ap_id: n.in_reply_to_ap_id,
      # 既定は空。読む口(`list_posts/2`・`get_post/2`)は `with_reactions/2`
      # でここを上書きする ── 書いたばかりの投稿は本当に空なので、
      # 書く口はそのままでいい。
      reactions: [],
      local_only: dn.local_only || false,
      as_article: dn.as_article || false
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
      local_only: false,
      as_article: false
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

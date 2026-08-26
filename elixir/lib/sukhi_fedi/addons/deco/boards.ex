# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Deco.Boards do
  @moduledoc """
  板そのもの ── 立てる、消す、話題を置く、知らせを受けるか決める、
  見たことにする。中に何が書かれたかは `Deco.Posts` の担当で、
  ここが持つのは器のほう。

  「読むのは、いつでも誰でも」の約束は `SukhiFedi.Addons.Deco` に
  一枚だけ置いてある。`list_decos/1` が `viewer_id` を受けるのは
  「気にかけているか」を立てるためだけで、**見える板の数は viewer で
  変わらない** ── ここに絞りを足すと、あの約束が落ちる。

  板が表札(`has_actor`)を出すと Group actor(`{slug}-deco@domain`)を
  持つ。個人アカウントの username はハイフンを使えないので、この形は
  名前空間が構造的にぶつからない。表札を出さない板は鍵を持たず、
  `get_actor_record/1` が `:not_found` を返す。
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Addons.Deco.View
  alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen
  alias SukhiFedi.Notes.Create, as: NotesCreate
  alias SukhiFedi.Schema.{Account, Deco, DecoNote, DecoPref, Note}

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
      |> View.deco(Map.get(counts, d.id, 0))
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

  **画面はまだ無い。** 作ったときの理由が違っていた ── 「話す板は題を
  持たないので、一覧で見分ける手がかりが要る」と書いたが、一覧が出して
  いるのは板の名前と説明で、投稿の題ではない。埋める穴が最初から無かった。

  IRC で `/topic` が効くのは、チャンネルに名前しか無いから。natadeco には
  `description` が既にあって「どんな板か」を持っている。ここが足せるのは
  「**いま**何の話か」で、それが要るのは板が忙しくて説明と離れてくるとき。
  まだその状況が来ていないので、口と列は置いたまま、画面だけ引っ込めた。
  要るようになったら、画面を出すだけでいい。

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
        {:ok, updated} -> {:ok, View.deco(updated, count_posts(updated.id))}
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
      %Deco{} = d -> {:ok, View.deco(d, count_posts(d.id))}
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
      {:ok, d} -> {:ok, View.deco(d, 0)}
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

  defp count_posts(deco_id) do
    Repo.one(from(dn in DecoNote, where: dn.deco_id == ^deco_id, select: count(dn.id))) || 0
  end

  # 呼び出し側は Account を持っていたり、id だけ持っていたりする
  # （`Notes.favourite/2` などの兄弟と同じ受け方に揃えてある）。
  defp id_of(%Account{id: id}), do: id
  defp id_of(id) when is_integer(id), do: id

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end

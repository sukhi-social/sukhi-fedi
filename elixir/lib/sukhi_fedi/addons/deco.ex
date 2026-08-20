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

  まだ連合しない。板の AP Group actor を生やすのは中身が固まってから
  で、それまでは投稿はふつうの public な note として外に出る。
  """

  use SukhiFedi.Addon, id: :deco

  import Ecto.Query

  alias SukhiFedi.{Notes, Repo}
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

  @spec create_deco(Account.t() | integer(), map()) ::
          {:ok, map()} | {:error, {:validation, map()}}
  def create_deco(%Account{id: aid}, attrs), do: create_deco(aid, attrs)

  def create_deco(account_id, attrs) when is_integer(account_id) do
    %Deco{}
    |> Deco.changeset(Map.put(stringify(attrs), "created_by_id", account_id))
    |> Repo.insert()
    |> case do
      {:ok, d} -> {:ok, view(d, 0)}
      {:error, cs} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
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
    with {:ok, %{id: deco_id}} <- get_deco(slug),
         :ok <- require_title(params) do
      write(id_of(author), deco_id, params)
    end
  end

  defp require_title(params) do
    params = stringify(params)

    case Map.get(params, "title") do
      t when is_binary(t) -> if String.trim(t) == "", do: title_missing(), else: :ok
      _ -> title_missing()
    end
  end

  defp title_missing, do: {:error, {:validation, %{title: ["を入れてください"]}}}

  @doc "板の投稿に、ぶら下げる。板は親の投稿から引く。"
  @spec reply(Account.t() | integer(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | atom() | {:validation, map()}}
  def reply(author, note_id, params) do
    case Repo.get_by(DecoNote, note_id: to_int(note_id)) do
      nil ->
        {:error, :not_found}

      %DecoNote{deco_id: deco_id, note_id: parent_id} ->
        parent = Repo.get(Note, parent_id)

        write(
          id_of(author),
          deco_id,
          Map.put(stringify(params), "in_reply_to_id", parent_ref(parent))
        )
    end
  end

  # 開設(INVITE_REQUIRED=false)は誰でも今すぐ入れる分、できたばかりの
  # アカウントが束にして書き込む道は塞いでおきたい。古参にはこの制限は
  # 掛からない ── 内部の目安であって、外に見せるバッジやランクにはしない。
  @new_account_window_h 24
  @new_account_min_gap_s 20

  defp write(account_id, deco_id, params) when is_integer(account_id) do
    params = stringify(params)

    with :ok <- check_pace(account_id) do
      # note を先に作り、そのあと板に結ぶ。note づくりは Notes 側の
      # トランザクション（outbox 込み）なので、こちらでは包めない。
      # 結びに失敗したら note は消す ── どこにも属さない投稿を残さない。
      case Notes.create_status(account_id, Map.put(params, "visibility", "public")) do
        {:ok, note} ->
          %DecoNote{}
          |> DecoNote.changeset(%{deco_id: deco_id, note_id: note.id})
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
          where: not is_nil(r.in_reply_to_ap_id),
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
       end)}
    end
  end

  # `coalesce(la.at, n.created_at)` の型が subquery を跨ぐと Ecto に
  # :utc_datetime として伝わらず、NaiveDateTime で返ってくることがある
  # ── notes.created_at は常に UTC で入っているので、その前提で戻す。
  defp to_utc(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")
  defp to_utc(%DateTime{} = t), do: t

  @doc "一件と、そのレス（古い順 ── 掲示板は上から下へ読むので）。"
  @spec get_post(integer() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_post(note_id) do
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
        {:ok, Map.put(post_view(note, dn, author), :replies, replies_of(note))}
    end
  end

  defp replies_of(%Note{} = parent) do
    case ap_id_of(parent) do
      nil ->
        []

      ap_id ->
        from(n in Note,
          join: dn in DecoNote,
          on: dn.note_id == n.id,
          join: a in Account,
          on: a.id == n.account_id,
          where: n.in_reply_to_ap_id == ^ap_id,
          order_by: [asc: n.id],
          select: {n, dn, a}
        )
        |> Repo.all()
        |> Enum.map(fn {n, dn, a} -> post_view(n, dn, a) end)
    end
  end

  # ── 形 ───────────────────────────────────────────────────────────────

  defp view(%Deco{} = d, post_count) do
    %{
      id: d.id,
      slug: d.slug,
      name: d.name,
      description: d.description,
      post_count: post_count,
      created_at: d.created_at
    }
  end

  defp post_view(%Note{} = n, %DecoNote{} = dn, %Account{} = author) do
    %{
      id: n.id,
      deco_id: dn.deco_id,
      title: n.title,
      content_html: Note.html(n),
      author: author_view(author),
      created_at: n.created_at,
      reply_count: reply_count(n)
    }
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

  defp reply_count(%Note{} = n) do
    case ap_id_of(n) do
      nil ->
        0

      ap_id ->
        Repo.one(
          from(r in Note,
            join: dn in DecoNote,
            on: dn.note_id == r.id,
            where: r.in_reply_to_ap_id == ^ap_id,
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

  defp parent_ref(%Note{id: id}), do: id
  defp parent_ref(nil), do: nil

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

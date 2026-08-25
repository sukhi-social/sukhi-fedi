# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Parents do
  @moduledoc """
  「この返信は、誰に向けた言葉か」を一段ぶんだけ。

  平らに並べる面（natadeco の話す板、友デコ）は、スレッドを組まない
  代わりに返信へ親を一枚添える ── IRC の `nick:` が一段しか指さないの
  と同じ深さで、それで会話は追える。祖父まで辿ると、画面が入れ子で
  埋まっていく。

  添えるのは思い出すぶんだけ（誰が・何を言っていたか一行）。本文を
  もう一度積まないのは、たいてい同じ画面のどこかに本体が居るから。

  一覧ぶんをまとめて一度に引く。行ごとに引くと、返信の数だけ問い合わせ
  が増える ── `Notes.reactions_for_notes/2` と同じ形。
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note}

  @excerpt_len 80

  @type summary :: %{
          id: integer(),
          author: %{
            username: String.t(),
            acct: String.t(),
            display_name: String.t(),
            avatar_url: String.t() | nil
          },
          excerpt: String.t()
        }

  @doc """
  返信先の AP id → その一行。手元に無い親（連合越しで取り込んでいない
  もの）は地図に載らない ── 呼ぶ側は「親はあるが、まだ知らない」を
  `nil` として扱う。
  """
  @spec by_ap_id([String.t()]) :: %{String.t() => summary()}
  def by_ap_id([]), do: %{}

  def by_ap_id(ap_ids) when is_list(ap_ids) do
    ap_ids = ap_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ap_ids == [] do
      %{}
    else
      from(n in Note,
        join: a in Account,
        on: a.id == n.account_id,
        where: n.ap_id in ^ap_ids,
        select: {n.ap_id, n, a}
      )
      |> Repo.all()
      |> Map.new(fn {ap_id, n, a} -> {ap_id, summarize(n, a)} end)
    end
  end

  @doc """
  note の id → その note が返している親の一行。

  ローカルの note は `ap_id` を持たない（公開 URL は必要なときに組む）
  ので、`in_reply_to_ap_id` から辿るのに加えて `/users/…/notes/:id` の
  形も id として拾う ── そうしないと、この鯖の中で交わされた会話だけ
  親が付かない、という妙な穴があく。
  """
  @spec for_note_ids([integer()]) :: %{integer() => summary()}
  def for_note_ids([]), do: %{}

  def for_note_ids(note_ids) when is_list(note_ids) do
    pairs =
      from(n in Note,
        where: n.id in ^note_ids and not is_nil(n.in_reply_to_ap_id),
        select: {n.id, n.in_reply_to_ap_id}
      )
      |> Repo.all()

    parents = pairs |> Enum.map(&elem(&1, 1)) |> by_ap_id()
    local = pairs |> Enum.map(&elem(&1, 1)) |> local_note_ids() |> by_local_id()

    Map.new(pairs, fn {id, parent_ap_id} ->
      {id, Map.get(parents, parent_ap_id) || Map.get(local, parent_ap_id)}
    end)
    |> Map.reject(fn {_id, v} -> is_nil(v) end)
  end

  # `https://<domain>/users/<u>/notes/<id>` から数字を拾う。他所の鯖の
  # URL がたまたま同じ形をしていても、下の引きが id で外れるだけ。
  defp local_note_ids(ap_ids) do
    domain = SukhiFedi.Config.domain!()

    for uri <- ap_ids,
        String.contains?(uri, domain),
        [_, id] <- [Regex.run(~r{/notes/(\d+)$}, uri)],
        into: %{},
        do: {uri, String.to_integer(id)}
  end

  defp by_local_id(uri_to_id) when map_size(uri_to_id) == 0, do: %{}

  defp by_local_id(uri_to_id) do
    ids = Map.values(uri_to_id)

    rows =
      from(n in Note,
        join: a in Account,
        on: a.id == n.account_id,
        where: n.id in ^ids,
        select: {n.id, n, a}
      )
      |> Repo.all()
      |> Map.new(fn {id, n, a} -> {id, summarize(n, a)} end)

    Map.new(uri_to_id, fn {uri, id} -> {uri, Map.get(rows, id)} end)
  end

  defp summarize(%Note{} = n, %Account{} = a) do
    %{
      id: n.id,
      author: %{
        username: a.username,
        acct: if(a.domain, do: "#{a.username}@#{a.domain}", else: a.username),
        display_name: a.display_name || a.username,
        avatar_url: a.avatar_url
      },
      excerpt: excerpt(n)
    }
  end

  # 親を思い出すぶんの一行。HTML を剥いで、一行に畳んで、切る。
  defp excerpt(%Note{} = n) do
    n
    |> Note.html()
    |> String.replace(~r{<[^>]*>}, "")
    |> String.replace(~r{\s+}, " ")
    |> String.trim()
    |> String.slice(0, @excerpt_len)
  end
end

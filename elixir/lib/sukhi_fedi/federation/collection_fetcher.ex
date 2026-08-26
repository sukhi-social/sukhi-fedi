# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.CollectionFetcher do
  @moduledoc """
  よその `OrderedCollection` を引いて、中身を並べて返す。

  この鯖は今まで、コレクションを**出す**コードしか持っていなかった
  (`Web.CollectionController` ほか)。actor 一枚(`ActorFetcher`)と
  note 一枚(`NoteFetcher`)は引けたが、一覧を辿る道具はゼロだった ──
  外の板を読むには、まずこれが要る。

  ## 引いて、置いていく

  引いたものは保存しない。ここが返すのは素の JSON の列で、`notes` にも
  `accounts` にも書かない。**見に行っただけ**の状態を、そのまま扱える
  ようにしてある ── ベランダの手すりは、ここが何も残さないことで
  できている。追うと決めたときは、そこから先は届いて残る道に移る。

  ## 上限を先に置く

  `first` / `next` を辿ると、相手の都合でいくらでも続きうる。頁数と
  件数の両方に上限を置いて、**足りなければ足りないまま返す**。黙って
  全部取りに行くと、こちらの都合ではなく相手の都合で時間が決まる。
  """

  alias SukhiFedi.Federation.{FedifyClient, UrlGuard}

  @default_pages 3
  @default_items 60
  @max_pages 10
  @max_items 200

  @type opts :: [pages: pos_integer(), items: pos_integer(), sign_as: map() | nil]

  @doc """
  `uri` のコレクションを引いて、`orderedItems` / `items` を平らに返す。

  返るのは `{:ok, items, %{pages: n, truncated: bool}}` ── 上限で
  切ったかどうかを一緒に返すのは、呼ぶ側が「ここまでです」と言えるように
  するため。黙って切ると、続きがあることを誰も知らない。
  """
  @spec fetch(String.t(), opts()) ::
          {:ok, [term()], %{pages: non_neg_integer(), truncated: boolean()}}
          | {:error, term()}
  def fetch(uri, opts \\ []) when is_binary(uri) do
    max_pages = opts |> Keyword.get(:pages, @default_pages) |> clamp(1, @max_pages)
    max_items = opts |> Keyword.get(:items, @default_items) |> clamp(1, @max_items)
    sign_as = Keyword.get(opts, :sign_as)

    with :ok <- guard(uri),
         {:ok, doc} <- get(uri, sign_as) do
      walk(entry_point(doc), doc, sign_as, max_pages, max_items, [], 0)
    end
  end

  # 最初の頁は、コレクション本体に載っていることも(`orderedItems`)、
  # `first` の先にあることもある。両方に対応する。
  defp entry_point(doc) do
    case doc["first"] do
      %{} = page -> {:page, page}
      uri when is_binary(uri) -> {:uri, uri}
      _ -> :inline
    end
  end

  defp walk(_next, _doc, _sign_as, max_pages, _max_items, acc, pages)
       when pages >= max_pages,
       do: {:ok, Enum.reverse(acc), %{pages: pages, truncated: true}}

  defp walk(:inline, doc, _sign_as, _max_pages, max_items, acc, pages) do
    {items, cut?} = take(items_of(doc), acc, max_items)
    {:ok, Enum.reverse(items ++ acc), %{pages: pages + 1, truncated: cut?}}
  end

  defp walk({:page, page}, _doc, sign_as, max_pages, max_items, acc, pages) do
    {items, cut?} = take(items_of(page), acc, max_items)
    acc = items ++ acc

    cond do
      cut? -> {:ok, Enum.reverse(acc), %{pages: pages + 1, truncated: true}}
      is_binary(page["next"]) -> walk({:uri, page["next"]}, nil, sign_as, max_pages, max_items, acc, pages + 1)
      true -> {:ok, Enum.reverse(acc), %{pages: pages + 1, truncated: false}}
    end
  end

  defp walk({:uri, uri}, _doc, sign_as, max_pages, max_items, acc, pages) do
    with :ok <- guard(uri),
         {:ok, page} <- get(uri, sign_as) do
      walk({:page, page}, nil, sign_as, max_pages, max_items, acc, pages)
    else
      _ ->
        # 途中で引けなくなったら、そこまでを返す ── 全部か何も無いか、
        # にしない。読める分だけ読めていい。
        {:ok, Enum.reverse(acc), %{pages: pages, truncated: true}}
    end
  end

  defp items_of(%{"orderedItems" => items}) when is_list(items), do: items
  defp items_of(%{"items" => items}) when is_list(items), do: items
  defp items_of(_), do: []

  defp take(items, acc, max_items) do
    room = max_items - length(acc)

    if length(items) > room,
      do: {Enum.reverse(Enum.take(items, room)), true},
      else: {Enum.reverse(items), false}
  end

  defp get(uri, sign_as) do
    case FedifyClient.fetch(uri, sign_as) do
      {:ok, %{"document" => doc}} when is_map(doc) -> {:ok, doc}
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      other -> {:error, other}
    end
  end

  # 相手の URL はこちらの入力から来る。内向きのアドレスへ行かせない。
  defp guard(uri) do
    if UrlGuard.safe?(uri), do: :ok, else: {:error, :unsafe_url}
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _hi), do: lo
end

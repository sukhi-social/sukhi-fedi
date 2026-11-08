# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MediaTranscode do
  @moduledoc """
  Remote media proxy の変換レイヤー。proxy URL の拡張子は CF edge cache に
  乗せるための飾りだが、`.webp` だけは「この形式で欲しい」の合図として
  読む(MediaProxyController.parse_id)。入力は jpeg / png の静止画。

  やることは一つだけ ─ WebP にして、その場で返す。WebP は encode が速い
  ので、リクエストの中で作ってしまう。置き場も裏の仕事も持たない:
  焼いた結果は CF の edge cache が持ち(proxy は長い cache-control を付ける)、
  edge から落ちたら、また一枚ぶん焼くだけ。

  これは正しさの層ではないので、迷ったら常に「原本をそのまま」に倒れる:
  対象外の形式・アニメーション・大きすぎる画像・encode 失敗・変換したのに
  縮まなかった・同時 encode の席が埋まっていた、ぜんぶ受け取ったままの
  bytes を返す。URL が `.webp` でも中身が jpeg のことがある、ということ ─
  ブラウザは content-type と中身で見るので、それで困らない。

  (以前は AVIF を裏で焼いて、できるまで WebP でつなぐ二段構えだった。
  1 コアの箱には重く、仕組みも多かったので外した。git の履歴に残っている。)
  """

  alias Vix.Vips.Image

  # 変換して意味がある入力だけ。svg はテキストのままが一番軽く、gif は
  # アニメーションごと壊れる。webp はもう webp なので、どれも触らない。
  @convertible ["image/jpeg", "image/png"]

  # decode を始める前の画素数の上限(4K)。Mastodon が添付に許すのと同じ
  # 値で、これ以上は decode バッファだけで数十 MB 食うので変換しない。
  @max_pixels 3840 * 2160

  # リクエストの中で同時に走る encode の数。cache miss が束で来たとき
  # (cold cache の 4 枚投稿など)にメモリを守る弁で、席が埋まっていたら
  # 変換せず原本を流すだけ。
  @max_concurrent 2
  @slots_key {__MODULE__, :slots}

  @doc """
  `variant` が `:webp` のとき、`body` を WebP に encode し直して
  `{body, content_type}` を返す。`nil` のとき、変換できないとき、
  しないほうがいいときは、受け取ったままの bytes を返す。
  """
  @spec maybe(binary(), String.t() | nil, nil | :webp) :: {binary(), String.t() | nil}
  def maybe(body, content_type, nil), do: {body, content_type}

  def maybe(body, content_type, :webp) do
    if normalize(content_type) in @convertible do
      case encode(body) do
        {:ok, out} -> {out, "image/webp"}
        :error -> {body, content_type}
      end
    else
      {body, content_type}
    end
  end

  defp encode(body) do
    case acquire() do
      {:ok, ref} ->
        try do
          transcode(body)
        after
          :atomics.sub(ref, 1, 1)
        end

      :busy ->
        :error
    end
  end

  # 変換の本体。ガードも smaller チェックも込みで、駄目なら理由を
  # 問わず :error(呼ぶ側はどのみち原本に倒れるだけなので)。
  defp transcode(body) do
    with {:ok, img} <- Image.new_from_buffer(body),
         true <- within_limits?(img),
         {:ok, out} <- Image.write_to_buffer(img, ".webp[Q=80]"),
         true <- byte_size(out) < byte_size(body) do
      {:ok, out}
    else
      _ -> :error
    end
  end

  defp within_limits?(img) do
    Image.width(img) * Image.height(img) <= @max_pixels and pages(img) == 1
  end

  # アニメーションは 2 ページ以上。new_from_buffer は既定で先頭 1 フレーム
  # しか読まないので、そのまま encode すると静止画に化ける ─ ここで見分けて、
  # 触らずに返す。静止画にはこのヘッダ自体が無いことが多い(それも 1 扱い)。
  defp pages(img) do
    case Image.header_value(img, "n-pages") do
      {:ok, n} when is_integer(n) -> n
      _ -> 1
    end
  end

  defp normalize(ct) when is_binary(ct) do
    ct |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end

  defp normalize(_), do: nil

  # encode 一回ぶんの席。:atomics なのでプロセスも lock も持たない。
  # 初回の put が競合して ref が二つできても、各自つかんだ ref に
  # 返しにいくので数はずれない。
  defp acquire do
    ref = slots()

    if :atomics.add_get(ref, 1, 1) <= @max_concurrent do
      {:ok, ref}
    else
      :atomics.sub(ref, 1, 1)
      :busy
    end
  end

  defp slots do
    case :persistent_term.get(@slots_key, nil) do
      nil ->
        ref = :atomics.new(1, [])
        :persistent_term.put(@slots_key, ref)
        ref

      ref ->
        ref
    end
  end
end

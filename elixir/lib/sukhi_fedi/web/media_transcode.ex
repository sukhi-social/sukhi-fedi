# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MediaTranscode do
  @moduledoc """
  Remote media proxy の変換レイヤー。proxy URL の拡張子は今まで CF edge
  cache に乗せるための飾りだったが、`.avif` / `.webp` だけは「この形式で
  欲しい」の合図として読む(MediaProxyController.parse_id)。ここで
  libvips(vix) が encode し直して、転送量を軽くする。

  これは正しさの層ではないので、迷ったら常に「原本をそのまま」に倒れる:
  対象外の形式・アニメーション・大きすぎる画像・encode 失敗・変換したのに
  縮まなかったとき、ぜんぶ受け取ったままの bytes を返す。URL が `.avif`
  でも中身が jpeg のことがある、ということ ─ ブラウザは content-type と
  中身で見るので、それで困らない。

  AVIF の Q=65 は libheif の換算で aom の cq-level ≒ 22
  (`cq = ((100 - Q) * 63 + 50) / 100`)。既定の Q=50 は cq ≒ 32 で、
  写真に見てわかる劣化が出るので上げてある。effort=2 は箱の 1 コアで
  cache miss のたびに何秒も待たせないための妥協(2MP のノイズ画像で
  effort=4 の約 1/10 の時間、サイズの損は数 %)。
  """

  alias Vix.Vips.Image

  # 変換して意味がある入力だけ。svg はテキストのままが一番軽く、gif は
  # アニメーションごと壊れるので、どちらも触らない。
  @convertible ["image/jpeg", "image/png", "image/webp"]

  @suffix %{avif: ".avif[Q=65,effort=2]", webp: ".webp[Q=80]"}
  @output_ct %{avif: "image/avif", webp: "image/webp"}

  # decode を始める前の画素数の上限(4K)。Mastodon が添付に許すのと同じ
  # 値で、これ以上は decode バッファだけで数十 MB 食うので変換しない。
  @max_pixels 3840 * 2160

  # 同時に走る encode の数。cache miss が束で来たとき(cold cache の
  # 4 枚投稿など)にメモリを守る弁で、席が埋まっていたら変換せず原本を
  # 流すだけ。
  @max_concurrent 2
  @slots_key {__MODULE__, :slots}

  @doc """
  `body` を `target` 形式に encode し直して `{body, content_type}` を
  返す。変換しない(できない)ときは受け取ったままの組を返す。
  """
  @spec maybe(binary(), String.t() | nil, :avif | :webp | nil) ::
          {binary(), String.t() | nil}
  def maybe(body, content_type, target) when target in [:avif, :webp] do
    ct = normalize(content_type)

    if ct in @convertible and ct != @output_ct[target] do
      case acquire() do
        {:ok, ref} ->
          try do
            transcode(body, content_type, target)
          after
            :atomics.sub(ref, 1, 1)
          end

        :busy ->
          {body, content_type}
      end
    else
      {body, content_type}
    end
  end

  def maybe(body, content_type, _target), do: {body, content_type}

  defp transcode(body, content_type, target) do
    with {:ok, img} <- Image.new_from_buffer(body),
         true <- Image.width(img) * Image.height(img) <= @max_pixels,
         1 <- pages(img),
         {:ok, out} <- Image.write_to_buffer(img, @suffix[target]),
         true <- byte_size(out) < byte_size(body) do
      {out, @output_ct[target]}
    else
      _ -> {body, content_type}
    end
  end

  # アニメーション(animated webp / apng)は 2 ページ以上。new_from_buffer
  # は既定で先頭 1 フレームしか読まないので、そのまま encode すると
  # 静止画に化ける ─ ここで見分けて、触らずに返す。静止画にはこの
  # ヘッダ自体が無いことが多い(それも 1 扱い)。
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

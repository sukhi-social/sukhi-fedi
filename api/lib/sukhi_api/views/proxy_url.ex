# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.ProxyUrl do
  @moduledoc """
  gateway の remote media proxy (`/proxy/{media,avatar,header}/:id`) の
  URL を組む。`MastodonMedia` と `MastodonAccount` の両方が使う。

  拡張子を飾りで付けるのが肝: Cloudflare は既定で URL の拡張子を見て
  キャッシュ対象を決めるので、`/proxy/media/6` のままだと origin が
  cache-control を付けても DYNAMIC のまま edge に乗らない。
  `/proxy/media/6.webp` なら乗る。gateway 側は拡張子を剥がして無視する。
  """

  @doc "リモート添付の proxy URL。元 URL の拡張子を引き継ぐ。"
  @spec media(integer(), String.t()) :: String.t()
  def media(id, remote_url) do
    "https://#{SukhiApi.Config.domain!()}/proxy/media/#{id}#{cache_ext(remote_url)}"
  end

  @doc """
  リモート avatar / header の proxy URL。`?v=` は元 URL のハッシュで、
  actor 更新で画像 URL が変われば CF cache も自然に外れる。
  """
  @spec profile_image(String.t(), integer(), String.t()) :: String.t()
  def profile_image(kind, id, url) when kind in ["avatar", "header"] do
    "https://#{SukhiApi.Config.domain!()}/proxy/#{kind}/#{id}#{cache_ext(url)}?v=#{:erlang.phash2(url)}"
  end

  @doc "リモートのアバターデコレーション(n 番目)の proxy URL。"
  @spec decoration(integer(), non_neg_integer(), String.t()) :: String.t()
  def decoration(id, n, url) do
    "https://#{SukhiApi.Config.domain!()}/proxy/deco/#{id}/#{n}#{cache_ext(url)}?v=#{:erlang.phash2(url)}"
  end

  # 変な拡張子は付けない ─ 無くても壊れない、edge に乗らないだけ。
  defp cache_ext(url) do
    ext =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> Path.extname()
      |> String.downcase()

    if ext =~ ~r/^\.[a-z0-9]{2,5}$/, do: ext, else: ""
  end
end

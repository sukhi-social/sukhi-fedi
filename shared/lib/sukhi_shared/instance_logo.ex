# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.InstanceLogo do
  @moduledoc """
  インスタンスのロゴ(`INSTANCE_LOGO_URL`)の読み方を決める一箇所。

  連合先は、このサーバのロゴを自分のやり方で拾う ── Mastodon 系は
  `/api/v2/instance` の `thumbnail` / `icon`、Misskey 系はトップページの
  `<link rel=icon>` と `/favicon.ico`、nodeinfo。どの道も、ここの
  `url/2` を通せば同じ画像を指す。

  値は `https://…` の絶対 URL か、`/…` のパス(自ドメインの `/uploads/…`
  など)。ほかの書きかた(空、`//host`、`javascript:` …)は無かったことに
  して、既定の `/favicon.png`(同梱の「好」)に戻す ── 設定の書きまちがいで
  ロゴが消えたり、変な行き先に飛ばしたりしないため。
  """

  @default_path "/favicon.png"

  @doc "ロゴを、連合先がそのまま開ける絶対 URL にして返す。"
  @spec url(String.t(), String.t() | nil) :: String.t()
  def url(domain, raw) when is_binary(domain) do
    case normalize(raw) do
      "/" <> _ = path -> "#{scheme(domain)}://#{domain}#{path}"
      "https://" <> _ = abs -> abs
      nil -> "#{scheme(domain)}://#{domain}#{@default_path}"
    end
  end

  @doc "設定値を `/…` か `https://…` に整える。使えないものは nil。"
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(raw) when is_binary(raw) do
    raw = String.trim(raw)

    cond do
      String.starts_with?(raw, "//") -> nil
      String.starts_with?(raw, "/") -> raw
      match?(%URI{scheme: "https", host: h} when is_binary(h) and h != "", URI.parse(raw)) -> raw
      true -> nil
    end
  end

  def normalize(_), do: nil

  @doc "設定されているか(既定のままか)。"
  @spec custom?(String.t() | nil) :: boolean()
  def custom?(raw), do: normalize(raw) != nil

  defp scheme("localhost" <> _), do: "http"
  defp scheme(_), do: "https"
end

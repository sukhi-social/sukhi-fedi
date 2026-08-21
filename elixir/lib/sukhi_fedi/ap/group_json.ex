# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.GroupJson do
  @moduledoc """
  Build the ActivityPub Group JSON-LD for a natadeco 板(デコ)。
  `SukhiFedi.AP.ActorJson`(個人アカウント用)の Group 版 ── 形は倣うが、
  デコには「フォロー中」「非公開」「移行」のような個人固有の概念が
  無いので、それらは持たせない。

  段階の最初(actor が引ける・webfinger で見つかる)だけをここで持つ。
  Follow の受理・followers/outbox の中身・Announce 中継はまだ先。
  """

  alias SukhiFedi.Schema.Deco

  @doc "デコの Group actor URI。preferredUsername は `{slug}-deco`。"
  @spec actor_uri(Deco.t() | String.t()) :: String.t()
  def actor_uri(%Deco{slug: slug}), do: actor_uri(slug)

  def actor_uri(slug) when is_binary(slug) do
    "https://#{SukhiFedi.Config.domain!()}/users/#{slug}-deco"
  end

  @doc "actor の preferredUsername(`{slug}-deco`)。ActorController/WebfingerController で使う。"
  @spec deco_username(Deco.t() | String.t()) :: String.t()
  def deco_username(%Deco{slug: slug}), do: deco_username(slug)
  def deco_username(slug) when is_binary(slug), do: "#{slug}-deco"

  @spec build_group(Deco.t()) :: map()
  def build_group(%Deco{} = deco) do
    domain = SukhiFedi.Config.domain!()
    actor_uri = actor_uri(deco)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        "https://w3id.org/security/multikey/v1",
        "https://w3id.org/security/data-integrity/v1"
      ],
      "id" => actor_uri,
      "type" => "Group",
      # 人が見に行く先は SPA の板ページ。actor の `id` とは別物。
      "url" => "https://#{domain}/d/#{deco.slug}",
      "preferredUsername" => deco_username(deco),
      "name" => deco.name,
      "summary" => deco.description || "",
      "inbox" => "#{actor_uri}/inbox",
      "outbox" => "#{actor_uri}/outbox",
      "followers" => "#{actor_uri}/followers",
      # 板は誰でも読める・誰でもフォローできる ── natadeco の「読むのは
      # 誰でも」をそのまま連合の側にも。
      "manuallyApprovesFollowers" => false,
      "discoverable" => true,
      "indexable" => true,
      "endpoints" => %{"sharedInbox" => "https://#{domain}/inbox"},
      "publicKey" => %{
        "id" => "#{actor_uri}#main-key",
        "owner" => actor_uri,
        "publicKeyPem" => deco.public_key_pem || ""
      }
    }
    |> maybe_put_assertion_method(deco, actor_uri)
    |> maybe_put_lang_map("nameMap", deco.name, deco.name_i18n)
    |> maybe_put_lang_map("summaryMap", deco.description, deco.description_i18n)
  end

  # AS2 の nameMap/summaryMap(FEP 抜きの素の仕様語彙)。主フィールドの
  # 言語＋上乗せぶんを一枚の地図にする ── 他言語が無ければ出さない
  # (bare な actor のまま)。
  #
  # 主フィールドがどの言語かは決め打ちできない(書いた人が実際に選んだ
  # 言語がそのまま入るので、ja とは限らない)。上乗せに入っている言語が
  # 「もう一方」なので、対応言語(ja/ko)のうち上乗せに無いほうが主言語 ──
  # 2 言語だけの前提で成り立つ、消去法の推定。
  defp maybe_put_lang_map(map, _key, _primary, i18n) when i18n in [nil, %{}], do: map

  defp maybe_put_lang_map(map, key, primary, i18n) do
    primary_lang = if Map.has_key?(i18n, "ja"), do: "ko", else: "ja"
    Map.put(map, key, Map.put(i18n, primary_lang, primary || ""))
  end

  defp maybe_put_assertion_method(map, %Deco{ed25519_public_multibase: mb}, actor_uri)
       when is_binary(mb) and mb != "" do
    Map.put(map, "assertionMethod", [
      %{
        "id" => "#{actor_uri}#ed25519-key",
        "type" => "Multikey",
        "controller" => actor_uri,
        "publicKeyMultibase" => mb
      }
    ])
  end

  defp maybe_put_assertion_method(map, _deco, _actor_uri), do: map
end

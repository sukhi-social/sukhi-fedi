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

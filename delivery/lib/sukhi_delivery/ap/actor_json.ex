# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.AP.ActorJson do
  @moduledoc """
  Build Person / Update(Person) JSON-LD for a local account.

  Mirrors `SukhiFedi.AP.ActorJson` on the gateway. Lives here because
  `Outbox.Consumer` runs on the delivery node and needs to fan out
  Update(Actor) without a round-trip back to the gateway.

  > ⚠️ Must stay shape-compatible with `SukhiFedi.AP.ActorJson` on the
  > gateway. Any key added on one side must be added on the other in
  > the same commit — see `SukhiDelivery.AP.ActorJsonTest`.
  """

  alias SukhiDelivery.Schema.Account

  @spec build_person(Account.t()) :: map()
  def build_person(%Account{} = account) do
    domain = SukhiDelivery.Config.domain!()
    actor_uri = "https://#{domain}/users/#{account.username}"

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        "https://w3id.org/security/multikey/v1",
        "https://w3id.org/security/data-integrity/v1",
        %{
          "featured" => %{"@id" => "toot:featured", "@type" => "@id"},
          "discoverable" => "toot:discoverable",
          "indexable" => "toot:indexable",
          "toot" => "http://joinmastodon.org/ns#",
          "pending" => "https://purl.archive.org/socialweb/pending#",
          "pendingFollowers" => %{"@id" => "pending:pendingFollowers", "@type" => "@id"},
          "pendingFollowing" => %{"@id" => "pending:pendingFollowing", "@type" => "@id"}
        }
      ],
      "id" => actor_uri,
      "type" => "Person",
      "preferredUsername" => account.username,
      "name" => account.display_name || account.username,
      "summary" => account.summary || "",
      "inbox" => "#{actor_uri}/inbox",
      "outbox" => "#{actor_uri}/outbox",
      "followers" => "#{actor_uri}/followers",
      "following" => "#{actor_uri}/following",
      "featured" => "#{actor_uri}/featured",
      "manuallyApprovesFollowers" => account.locked || false,
      # FEP-5feb search-indexing consent. Always emitted (false is a
      # meaningful "no"), so a remote never has to guess our default.
      "discoverable" => account.discoverable || false,
      "indexable" => account.indexable || false,
      "endpoints" => %{"sharedInbox" => "https://#{domain}/inbox"},
      "publicKey" => %{
        "id" => "#{actor_uri}#main-key",
        "owner" => actor_uri,
        "publicKeyPem" => account.public_key_pem || ""
      }
    }
    |> maybe_put_assertion_method(account, actor_uri)
    |> maybe_put_image("icon", account.avatar_url)
    |> maybe_put_image("image", account.banner_url)
    |> maybe_put_fields(account.fields)
    |> maybe_put_also_known_as(account.aliases)
    |> maybe_put_moved_to(account.moved_to_uri)
    |> maybe_put_pending_collections(account, actor_uri)
  end

  # FEP-4ccd: a locked actor advertises where its pending follow requests
  # live (owner-only collections; here we only publish the URIs). Unlocked
  # actors auto-accept, so they never hold pending followers — bare actor.
  defp maybe_put_pending_collections(map, %Account{locked: true}, actor_uri) do
    map
    |> Map.put("pendingFollowers", "#{actor_uri}/pendingFollowers")
    |> Map.put("pendingFollowing", "#{actor_uri}/pendingFollowing")
  end

  defp maybe_put_pending_collections(map, _account, _actor_uri), do: map

  # Profile fields ride as AP `attachment` PropertyValue rows — the shape
  # Mastodon and Misskey/Sharkey both render — so a remote viewer sees the
  # same rows a local one does. Omitted entirely when the person has none,
  # so a bare actor stays bare (same as icon/image).
  defp maybe_put_fields(map, [_ | _] = fields) do
    Map.put(map, "attachment", Enum.map(fields, &property_value/1))
  end

  defp maybe_put_fields(map, _), do: map

  defp property_value(%{"name" => name, "value" => value}) do
    %{"type" => "PropertyValue", "name" => name, "value" => value}
  end

  # FEP-521a: the Ed25519 key (FEP-8b32 Object Integrity Proofs) rides
  # as an `assertionMethod` Multikey. Without this entry remote servers
  # cannot resolve our proofs' verificationMethod and reject them.
  defp maybe_put_assertion_method(map, %Account{ed25519_public_multibase: mb}, actor_uri)
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

  defp maybe_put_assertion_method(map, _account, _actor_uri), do: map

  # Account migration (Mastodon Move). Mirrors the gateway's ActorJson:
  # `alsoKnownAs` is the prior-identity set (consent for an inbound Move),
  # `movedTo` is the forward redirect on a moved-away actor. Both omitted
  # when absent.
  defp maybe_put_also_known_as(map, [_ | _] = aliases),
    do: Map.put(map, "alsoKnownAs", aliases)

  defp maybe_put_also_known_as(map, _), do: map

  defp maybe_put_moved_to(map, uri) when is_binary(uri) and uri != "",
    do: Map.put(map, "movedTo", uri)

  defp maybe_put_moved_to(map, _), do: map

  defp maybe_put_image(map, _key, nil), do: map
  defp maybe_put_image(map, _key, ""), do: map

  defp maybe_put_image(map, key, url) do
    Map.put(map, key, %{
      "type" => "Image",
      "mediaType" => media_type_for(url),
      "url" => url
    })
  end

  defp media_type_for(url) do
    case url |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  @spec build_update(Account.t()) :: map()
  def build_update(%Account{} = account) do
    actor_uri = actor_uri(account)
    domain = SukhiDelivery.Config.domain!()

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => "https://#{domain}/activities/update/#{random_id()}",
      "type" => "Update",
      "actor" => actor_uri,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["#{actor_uri}/followers"],
      "object" => build_person(account)
    }
  end

  defp actor_uri(%Account{username: u}) do
    domain = SukhiDelivery.Config.domain!()
    "https://#{domain}/users/#{u}"
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

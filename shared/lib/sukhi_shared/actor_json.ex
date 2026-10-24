defmodule SukhiShared.ActorJson do
  @moduledoc """
  ActivityPub Person JSON-LD for a local account, and the Update(Person)
  wrapper sent to followers when the actor's public state changes.

  One copy for both the gateway and the delivery node: the gateway serves
  the actor, and `Outbox.Consumer` on the delivery node fans out
  Update(Actor) without a round-trip back. Each app keeps a thin
  `AP.ActorJson` that supplies its own `Config.domain!()`; this module only
  reads fields off the account, so it works on either app's `Account`.
  """

  alias SukhiShared.Capability

  @spec actor_uri(String.t(), map() | String.t()) :: String.t()
  def actor_uri(domain, %{username: u}), do: actor_uri(domain, u)

  def actor_uri(domain, username) when is_binary(username) do
    "https://#{domain}/users/#{username}"
  end

  @doc """
  人が読む頁のありか(`build_person/1` の `"url"`)。`actor_uri/1` と対に
  なる一箇所 ── webfinger の `profile-page` link もここを見るので、
  actor JSON の言う行き先と webfinger の言う行き先が食い違わない。
  """
  @spec profile_uri(String.t(), map() | String.t()) :: String.t()
  def profile_uri(domain, %{username: u}), do: profile_uri(domain, u)

  def profile_uri(domain, username) when is_binary(username) do
    "https://#{domain}/@#{username}"
  end

  @spec build_person(String.t(), map()) :: map()
  def build_person(domain, account) do
    actor_uri = actor_uri(domain, account)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        "https://w3id.org/security/multikey/v1",
        "https://w3id.org/security/data-integrity/v1",
        "https://w3id.org/fep/844e",
        Map.merge(Capability.context_terms(), %{
          "featured" => %{"@id" => "toot:featured", "@type" => "@id"},
          "discoverable" => "toot:discoverable",
          "indexable" => "toot:indexable",
          "toot" => "http://joinmastodon.org/ns#",
          "Emoji" => "toot:Emoji",
          "vcard" => "http://www.w3.org/2006/vcard/ns#",
          "pending" => "https://purl.archive.org/socialweb/pending#",
          "pendingFollowers" => %{"@id" => "pending:pendingFollowers", "@type" => "@id"},
          "pendingFollowing" => %{"@id" => "pending:pendingFollowing", "@type" => "@id"}
        })
      ],
      "id" => actor_uri,
      "type" => "Person",
      # **人が読む頁のありか。** `id` とは別のもの ── `id` は機械の識別子で、
      # `url` は「この人を見に行くならここ」。これが無いので、actor を引いた
      # 道具(fedify lookup など)はプロフィールへのリンクを出しようがなかった。
      # 行き先は書かれていなかっただけで、頁のほうは前からある。
      "url" => profile_uri(domain, account),
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
      "endpoints" => Map.merge(%{"sharedInbox" => "https://#{domain}/inbox"}, Capability.endpoints(domain)),
      "publicKey" => %{
        "id" => "#{actor_uri}#main-key",
        "owner" => actor_uri,
        "publicKeyPem" => account.public_key_pem || ""
      }
    }
    |> maybe_put_assertion_method(account, actor_uri)
    |> maybe_put_generator()
    |> maybe_put_image("icon", account.avatar_url)
    |> maybe_put_image("image", account.banner_url)
    |> maybe_put_fields(account.fields)
    |> maybe_put_vcard(account)
    |> maybe_put_emoji_tags(Map.get(account, :emojis))
    |> maybe_put_also_known_as(account.aliases)
    |> maybe_put_moved_to(account.moved_to_uri)
    |> maybe_put_pending_collections(account, actor_uri)
  end

  # FEP-844e: what this server implements, under `generator`. Omitted when
  # nothing is advertised (`Capability.generator/0` is nil).
  defp maybe_put_generator(map) do
    case Capability.generator() do
      nil -> map
      gen -> Map.put(map, "generator", gen)
    end
  end

  # FEP-4ccd: a locked actor advertises where its pending follow requests
  # live. The collections themselves are owner-only; here we only publish
  # the URIs so a client knows they exist. Unlocked actors auto-accept, so
  # they never hold pending followers — their actor stays bare.
  defp maybe_put_pending_collections(map, %{locked: true}, actor_uri) do
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

  # Misskey-style location and birthday, as the `vcard:` keys Misskey and its
  # forks read. Omitted when unset, so a bare actor stays bare.
  defp maybe_put_vcard(map, account) do
    map
    |> put_present("vcard:Address", Map.get(account, :location))
    |> put_present("vcard:bday", account |> Map.get(:birthday) |> bday())
  end

  defp put_present(map, _key, v) when v in [nil, ""], do: map
  defp put_present(map, key, v), do: Map.put(map, key, v)

  defp bday(%Date{} = d), do: Date.to_iso8601(d)
  defp bday(_), do: nil

  # The custom emoji the name / bio / fields wear, as AP `Emoji` tags — the
  # same shape notes carry — so a remote viewer swaps `:blobcat:` for the
  # image. Rows without a url can't be drawn there, so they are dropped.
  defp maybe_put_emoji_tags(map, [_ | _] = emojis) do
    tags =
      for %{"shortcode" => sc, "url" => url} <- emojis,
          is_binary(sc) and sc != "" and is_binary(url) and url != "" do
        %{
          "id" => url,
          "type" => "Emoji",
          "name" => ":#{sc}:",
          "icon" => %{"type" => "Image", "url" => url}
        }
      end

    if tags == [], do: map, else: Map.put(map, "tag", tags)
  end

  defp maybe_put_emoji_tags(map, _), do: map

  defp property_value(%{"name" => name, "value" => value}) do
    %{"type" => "PropertyValue", "name" => name, "value" => value}
  end

  # FEP-521a: the Ed25519 key (FEP-8b32 Object Integrity Proofs) rides
  # as an `assertionMethod` Multikey. Without this entry remote servers
  # cannot resolve our proofs' verificationMethod and reject them.
  defp maybe_put_assertion_method(map, %{ed25519_public_multibase: mb}, actor_uri)
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

  # Account migration (Mastodon Move). `alsoKnownAs` lists the prior
  # identities the user has claimed as "also me"; a destination server
  # reading this is how a Move *to* us is verified bidirectionally on
  # their side. `movedTo` is set on the *old* identity once it has moved,
  # so remotes follow the redirect. Both omitted when absent, so a bare
  # actor stays bare.
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

  @spec build_update(String.t(), map()) :: map()
  def build_update(domain, account) do
    actor_uri = actor_uri(domain, account)

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
      "object" => build_person(domain, account)
    }
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

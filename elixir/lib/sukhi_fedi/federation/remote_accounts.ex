# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.RemoteAccounts do
  @moduledoc """
  Upsert remote ActivityPub actors into the local `accounts` directory
  as **shadow rows** (`domain IS NOT NULL`).

  Shadow rows are what lets `Follow`/`Note`/`Reaction` etc. keep their
  cheap integer FK to `accounts.id` while still pointing at a remote
  Person. There is no public-key material *we own* on a shadow row —
  `public_key_pem` here is the *remote's* key, used by the inbound
  signature verifier, not the outbound signer.
  """

  alias SukhiFedi.AP.Emojis
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  @doc """
  Upsert an Account from a parsed ActivityPub Actor JSON map.

  Idempotent on `actor_uri`. Returns `{:ok, account}` on success, or
  `{:error, reason}` on malformed input.

  When `expected_uri` is given (the URL we actually fetched), the actor's
  own `id` host must match it. This stops a server at evil.example from
  serving a document claiming `id: https://good.example/users/alice` and
  impersonating / overwriting that actor's shadow row.
  """
  @spec upsert_from_actor_json(map(), String.t() | nil) ::
          {:ok, Account.t()} | {:error, term()}
  def upsert_from_actor_json(actor_json, expected_uri \\ nil)

  def upsert_from_actor_json(actor_json, expected_uri) when is_map(actor_json) do
    with {:ok, actor_uri} <- fetch(actor_json, "id"),
         :ok <- check_expected_host(actor_uri, expected_uri),
         {:ok, username} <- fetch_username(actor_json),
         {:ok, domain} <- fetch_domain(actor_uri) do
      # Identity + freshness are always written; everything else is "mergeable"
      # so a degraded or partial refetch (a remote mid-migration, a leaner Person
      # from a different software version) can't null a good avatar, bio, inbox
      # or signing key. A legitimate change still applies — we only *skip* a
      # field when the fetched value is blank.
      identity = %{
        actor_uri: actor_uri,
        username: username,
        domain: domain,
        last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      mergeable = %{
        display_name: actor_json["name"],
        summary: actor_json["summary"],
        fields: property_values(actor_json["attachment"]),
        emojis: Emojis.from_tag(actor_json["tag"]),
        inbox_url: actor_json["inbox"],
        shared_inbox_url: shared_inbox(actor_json),
        public_key_id: get_in(actor_json, ["publicKey", "id"]),
        public_key_pem: get_in(actor_json, ["publicKey", "publicKeyPem"]),
        avatar_url: image_url(actor_json["icon"]),
        banner_url: image_url(actor_json["image"]),
        # Account-migration mirror: the other identities this actor declares
        # as "also me" (`alsoKnownAs`) and the identity it has moved to
        # (`movedTo`). The inbound Move handler reads the *new* actor's
        # `aliases` to confirm bidirectional consent; `moved_to_uri` lets
        # every screen render the truthful "moved to @new" state.
        aliases: also_known_as(actor_json["alsoKnownAs"]),
        moved_to_uri: moved_to(actor_json["movedTo"])
      }

      # Location and birthday are the person's to take back, so on a complete
      # Person (one that carries its inbox) absence means "cleared" and the
      # mirror drops them; a degraded doc leaves them alone, like the rest.
      identity = Map.merge(identity, entries(actor_json))

      case Repo.get_by(Account, actor_uri: actor_uri) do
        nil ->
          # New row: blanks are fine; restore the historical defaults so a
          # nameless actor still shows its handle and summary is "" not nil.
          attrs = Map.merge(identity, insert_defaults(mergeable, username))
          %Account{} |> Account.changeset_remote(attrs) |> Repo.insert() |> then_decorate(actor_json)

        %Account{} = existing ->
          # Merge only the fields the fetched doc actually carries.
          attrs = Map.merge(identity, present_only(mergeable))
          existing |> Account.changeset_remote(attrs) |> Repo.update() |> then_decorate(actor_json)
      end
    end
  end

  def upsert_from_actor_json(_, _), do: {:error, :invalid_actor}

  # Avatar decorations are not in the Person document; a Misskey-family origin
  # serves them from its own API. Read them in the background, only for actors
  # that say they are Misskey-family (so no other server is ever asked).
  defp then_decorate({:ok, %Account{id: id}} = ok, actor_json) do
    learn_capabilities(actor_json)

    if misskey_family?(actor_json) do
      %{account_id: id}
      |> SukhiFedi.Federation.MisskeyDecorationsWorker.new()
      |> then(&Oban.insert(SukhiFedi.Oban, &1))
    end

    ok
  end

  defp then_decorate(other, _actor_json), do: other

  # FEP-844e: remember what the actor's host says it implements. A failure
  # here must never fail the ingest that found the document.
  defp learn_capabilities(actor_json) do
    SukhiShared.PeerCapabilities.learn(Repo, actor_json)
  rescue
    e -> require Logger; Logger.warning("peer capabilities: #{Exception.message(e)}")
  end

  # Misskey and its forks declare the `misskey` namespace in `@context`
  # (`"misskey": "https://misskey-hub.net/ns#"`) and publish `isCat`.
  @doc false
  def misskey_family?(%{"@context" => ctx}) when is_list(ctx) do
    Enum.any?(ctx, fn
      %{"misskey" => _} -> true
      _ -> false
    end)
  end

  def misskey_family?(%{"@context" => %{"misskey" => _}}), do: true
  def misskey_family?(_), do: false

  defp check_expected_host(_actor_uri, nil), do: :ok

  defp check_expected_host(actor_uri, expected_uri) do
    case {host_of(actor_uri), host_of(expected_uri)} do
      {h, h} when is_binary(h) -> :ok
      _ -> {:error, :id_host_mismatch}
    end
  end

  defp host_of(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> nil
    end
  end

  defp host_of(_), do: nil

  defp fetch(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing, key}}
    end
  end

  defp fetch_username(actor_json) do
    case Map.get(actor_json, "preferredUsername") do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        # Fall back to the last path segment of the id. Misskey/Mastodon
        # always set preferredUsername; this is defensive.
        with {:ok, uri} <- fetch(actor_json, "id"),
             %URI{path: path} when is_binary(path) <- URI.parse(uri),
             [_ | _] = parts <- String.split(path, "/", trim: true) do
          {:ok, List.last(parts)}
        else
          _ -> {:error, :no_username}
        end
    end
  end

  defp fetch_domain(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, :no_domain}
    end
  end

  defp shared_inbox(actor_json) do
    case get_in(actor_json, ["endpoints", "sharedInbox"]) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp image_url(%{"url" => url}) when is_binary(url), do: url
  defp image_url(url) when is_binary(url), do: url
  defp image_url(_), do: nil

  # `alsoKnownAs` is a set of actor URIs. Mastodon emits an array; AS2
  # allows a single string, so we tolerate both. Keep only well-formed
  # http(s) URIs — a blank or non-URI entry would never match a Move's
  # actor anyway, and we don't want junk in the consent check.
  defp also_known_as(uris) when is_list(uris), do: uris |> Enum.flat_map(&aka_uri/1) |> Enum.uniq()

  defp also_known_as(uri) when is_binary(uri), do: aka_uri(uri)
  defp also_known_as(_), do: []

  defp aka_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> [uri]
      _ -> []
    end
  end

  defp aka_uri(_), do: []

  # `movedTo` is a single actor URI (the identity this actor migrated to).
  defp moved_to(uri) when is_binary(uri) do
    case aka_uri(uri) do
      [u] -> u
      [] -> nil
    end
  end

  defp moved_to(_), do: nil

  # Pull the actor's `attachment` PropertyValue rows into our profile
  # `fields` shape. Non-PropertyValue attachments (some servers attach
  # images here) are ignored. The values land in `changeset_remote`,
  # whose `cast_fields` gate sanitizes and caps them — same as our own.
  defp entries(%{"inbox" => inbox} = actor_json) when is_binary(inbox) do
    %{
      location: text_or_nil(actor_json["vcard:Address"]),
      birthday: birthday(actor_json["vcard:bday"])
    }
  end

  defp entries(_), do: %{}

  defp text_or_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp text_or_nil(_), do: nil

  # Misskey sends `YYYY-MM-DD`; anything else (or a bad date) is no birthday.
  defp birthday(<<date::binary-size(10), _::binary>>) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp birthday(_), do: nil

  defp property_values(attachment) when is_list(attachment) do
    Enum.flat_map(attachment, fn
      %{"type" => "PropertyValue", "name" => name, "value" => value}
      when is_binary(name) and is_binary(value) ->
        [%{"name" => name, "value" => value}]

      _ ->
        []
    end)
  end

  defp property_values(_), do: []

  # Keep only fields with a present value, so an update never clobbers a stored
  # value with a blank one from a partial refetch.
  defp present_only(map) do
    map |> Enum.reject(fn {_k, v} -> blank?(v) end) |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false

  # On a brand-new shadow row there's nothing to preserve, so restore the
  # original fallbacks: display_name → the handle, summary → "".
  defp insert_defaults(mergeable, username) do
    mergeable
    |> Map.update!(:display_name, fn name -> name || username end)
    |> Map.update!(:summary, fn summary -> summary || "" end)
  end
end

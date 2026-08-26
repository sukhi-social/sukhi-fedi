# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.NoteController do
  @moduledoc """
  Serves individual Note objects as AP JSON-LD.

  Remote servers dereference a Note id to hydrate the object after
  receiving a Create activity that only referenced it, and to refresh
  a cached copy. Without this endpoint the note shows up in the
  recipient's inbox but is dropped or rendered as broken on timelines
  (observed on iceshrimp → watcher-hackers_pub: "1 posts" on the
  profile but the posts tab stays empty).
  """

  import Plug.Conn
  alias SukhiFedi.AP.{ActorJson, MediaSerialize, Titled}
  alias SukhiFedi.Notes.Replies
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note}

  @public_ns "https://www.w3.org/ns/activitystreams#Public"

  # FEP-044f quote vocabulary, so a dereferenced note carries the same
  # `quote` / `interactionPolicy` / `quoteAuthorization` as the delivered
  # Create. `gotosocial.org/ns` supplies the interaction-policy terms.
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://gotosocial.org/ns",
    %{
      "misskey" => "https://misskey-hub.net/ns#",
      "quote" => %{"@id" => "https://w3id.org/fep/044f#quote", "@type" => "@id"},
      "quoteUrl" => "as:quoteUrl",
      "_misskey_quote" => "misskey:_misskey_quote",
      "quoteAuthorization" => %{
        "@id" => "https://w3id.org/fep/044f#quoteAuthorization",
        "@type" => "@id"
      }
    }
  ]

  @quote_policy %{"canQuote" => %{"automaticApproval" => [@public_ns]}}

  def show(conn, _opts) do
    username = conn.path_params["name"]
    note_id_raw = conn.path_params["note_id"]
    actor_uri = ActorJson.actor_uri(username)

    with {note_id, ""} <- Integer.parse(note_id_raw || ""),
         %Account{id: aid} <- SukhiFedi.Accounts.by_local_username(username),
         %Note{} = note <- Repo.get(Note, note_id),
         true <- note.account_id == aid,
         true <- note.visibility == "public" do
      note = Repo.preload(note, :media)
      send_json(conn, 200, note_to_ap(note, actor_uri, username))
    else
      _ -> send_json(conn, 404, %{error: "not found"})
    end
  end

  # FEP-7458 replies collection for a public note. Same resolution as
  # `show/1`; the items are the public replies pointing back at this note.
  def replies(conn, _opts) do
    username = conn.path_params["name"]
    note_id_raw = conn.path_params["note_id"]
    actor_uri = ActorJson.actor_uri(username)

    with {note_id, ""} <- Integer.parse(note_id_raw || ""),
         %Account{id: aid} <- SukhiFedi.Accounts.by_local_username(username),
         %Note{} = note <- Repo.get(Note, note_id),
         true <- note.account_id == aid,
         true <- note.visibility == "public" do
      note_uri = "#{actor_uri}/notes/#{note.id}"
      parent_ap_ids = Enum.uniq([note_uri | List.wrap(note.ap_id)])
      items = Replies.public_reply_uris(parent_ap_ids)

      send_json(conn, 200, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{note_uri}/replies",
        "type" => "OrderedCollection",
        "totalItems" => length(items),
        "orderedItems" => items
      })
    else
      _ -> send_json(conn, 404, %{error: "not found"})
    end
  end

  defp note_to_ap(%Note{} = n, actor_uri, username) do
    # 題つきの投稿が線の上で名乗るぶんは `SukhiFedi.AP.Titled` が組む ──
    # 配る側(`Fedi.Builders`)と同じ一箇所。ここを別に書くと、返信されて
    # 引かれたときにだけ題が消える、という見つけにくい形になる（実際に
    # 一度そうなっていた）。
    wire = deco_wire_info(n.id)
    handle = Titled.handle(username)

    %{
      "@context" => @context,
      "id" => "#{actor_uri}/notes/#{n.id}",
      "type" => Titled.type(wire.as_article, n.title),
      # 人が読む頁のありか。`id` は機械の識別子なので、別に要る ──
      # 無いと、受け取った側は「元の投稿を見る」の行き先を作れない。
      # actor と同じ抜けかたをしていた。
      "url" => "https://#{SukhiFedi.Config.domain!()}/@#{username}/#{n.id}",
      "attributedTo" => actor_uri,
      # AP `content` is HTML by contract, so the rendered form goes out.
      "content" => Titled.content(Note.html(n), n.title, handle, actor_uri),
      "published" => DateTime.to_iso8601(n.created_at),
      "to" => [@public_ns],
      "cc" => ["#{actor_uri}/followers"],
      # FEP-7458: where the thread under this note can be discovered.
      "replies" => "#{actor_uri}/notes/#{n.id}/replies",
      # We let anyone quote our public posts with automatic approval.
      "interactionPolicy" => @quote_policy
    }
    |> put_if("name", n.title)
    |> put_if("audience", wire.audience)
    |> put_if("summary", Titled.summary(n.cw, wire.as_article, n.title, Note.html(n)))
    |> put_mention(n.title, handle, actor_uri)
    |> put_quote(n)
    |> put_attachment(n.media)
  end

  defp put_mention(map, title, handle, actor_uri) do
    with true <- Titled.titled?(title),
         %{} = tag <- Titled.mention(handle, actor_uri) do
      Map.put(map, "tag", List.wrap(map["tag"] || []) ++ [tag])
    else
      _ -> map
    end
  end

  # deco addon を切ってあるインスタンスでは、板の話は無い。
  defp deco_wire_info(note_id) do
    if SukhiFedi.Addon.Registry.enabled?(:deco) do
      SukhiFedi.Addons.Deco.wire_info(note_id)
    else
      %{audience: nil, as_article: false}
    end
  end

  # FEP-044f canonical `quote` + the Misskey aliases, plus the
  # authorization stamp once a quoted author granted us one.
  defp put_quote(object, %Note{quote_of_ap_id: q} = n) when is_binary(q) and q != "" do
    object
    |> Map.put("quote", q)
    |> Map.put("quoteUrl", q)
    |> Map.put("_misskey_quote", q)
    |> put_if("quoteAuthorization", n.quote_authorization_ap_id)
  end

  defp put_quote(object, _), do: object

  defp put_if(object, _key, value) when value in [nil, ""], do: object
  defp put_if(object, key, value), do: Map.put(object, key, value)

  defp put_attachment(object, media) when is_list(media) and media != [] do
    Map.put(object, "attachment", MediaSerialize.ap_attachments(media))
  end

  defp put_attachment(object, _), do: object

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(status, JSON.encode!(body))
  end
end

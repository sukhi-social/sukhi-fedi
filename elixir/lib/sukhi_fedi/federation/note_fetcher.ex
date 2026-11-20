# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.NoteFetcher do
  @moduledoc """
  Fetch a remote `Note` (or `Article` / `Question`) and mirror it into
  the local `notes` table so timelines, replies, and AP-id resolution
  can treat it like any other row.

  Idempotent: a row already keyed by the same `ap_id` is returned
  as-is. The actor is upserted via `Federation.ActorFetcher` +
  `Federation.RemoteAccounts.upsert_from_actor_json/1`.

  This deliberately mirrors only enough fields for our Mastodon view to
  render a sensible Status — content, visibility from the audience,
  in_reply_to_ap_id. Reactions and engagement counts stay on the
  origin server.
  """

  alias SukhiFedi.Accounts
  alias SukhiFedi.AP.{Emojis, MediaIngest, Published}
  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.{Polls, Repo}
  alias SukhiFedi.Schema.{Account, Note}
  alias SukhiFedi.Federation.{ActorFetcher, FedifyClient, RemoteAccounts}

  @public_ns "https://www.w3.org/ns/activitystreams#Public"

  @spec fetch_and_mirror(String.t()) :: {:ok, Note.t()} | {:error, term()}
  def fetch_and_mirror(uri) when is_binary(uri) do
    case Repo.get_by(Note, ap_id: uri) do
      %Note{} = n ->
        {:ok, n}

      nil ->
        with {:ok, note_json} <- fetch_object(uri),
             {:ok, %Account{id: account_id}} <- resolve_attributed_to(note_json) do
          insert_note(note_json, account_id, uri)
        end
    end
  end

  # Fetch via the Bun `fedify.fetch.v1` endpoint so the GET is
  # HTTP-signed for Mastodon Secure Mode / Misskey auth-fetch-required
  # peers. The `notes` table is the cache — `fetch_and_mirror/1` checks
  # it first — so the Bun hop only happens on a genuine miss.
  #
  # An id can name an *activity*: a group's FEP-1b12 `Announce{Create}` points
  # at the Create, not the note. An activity is not a note, and mirroring it
  # would store an empty row under the activity's id — refuse it here, where
  # the document first arrives.
  @activity_types ~w(Create Update Delete Announce Like EmojiReact Undo Follow
                     Accept Reject Add Remove Move Block Flag Join Leave)

  defp fetch_object(uri) do
    case FedifyClient.fetch(uri, SukhiFedi.Accounts.signing_identity()) do
      {:ok, %{"document" => %{"type" => type}}} when type in @activity_types ->
        {:error, {:not_a_note, type}}

      {:ok, %{"document" => doc}} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:unexpected_fetch_result, other}}
      {:error, _} = err -> err
    end
  end

  defp resolve_attributed_to(note_json) do
    case attributed_uri(note_json) do
      nil ->
        {:error, :no_actor}

      uri ->
        case Accounts.by_actor_uri(uri) do
          %Account{} = a ->
            {:ok, a}

          nil ->
            with {:ok, actor_json} <- ActorFetcher.fetch(uri),
                 {:ok, %Account{} = a} <- RemoteAccounts.upsert_from_actor_json(actor_json, uri) do
              {:ok, a}
            end
        end
    end
  end

  defp attributed_uri(%{"attributedTo" => v}), do: extract(v)
  defp attributed_uri(%{"actor" => v}), do: extract(v)
  defp attributed_uri(_), do: nil

  defp extract(v) when is_binary(v), do: v
  defp extract(%{"id" => id}) when is_binary(id), do: id
  defp extract(_), do: nil

  # Misskey/forks signal a quote-note with a top-level field; FEP-e232
  # servers use a `tag` Link. Mirror whichever is present so the link
  # survives the fetch.
  defp quote_uri(note) do
    extract(note["quoteUrl"]) || extract(note["quoteUri"]) ||
      extract(note["_misskey_quote"]) || quote_uri_from_tag(note["tag"])
  end

  defp quote_uri_from_tag(tags) when is_list(tags) do
    Enum.find_value(tags, fn
      %{"type" => "Link"} = link ->
        rel = link["rel"]

        cond do
          is_binary(rel) and
              (String.contains?(rel, "_misskey_quote") or String.contains?(rel, "e232")) ->
            extract(link["href"])

          is_list(rel) and
              Enum.any?(
                rel,
                &(is_binary(&1) and
                      (String.contains?(&1, "_misskey_quote") or String.contains?(&1, "e232")))
              ) ->
            extract(link["href"])

          true ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp quote_uri_from_tag(_), do: nil

  # MFM source travels as `_misskey_content` or a `source` object;
  # mirror it so the Misskey markup survives the fetch.
  defp mfm_source(%{"_misskey_content" => s}) when is_binary(s) and s != "", do: s
  defp mfm_source(%{"source" => %{"content" => s}}) when is_binary(s) and s != "", do: s
  defp mfm_source(_), do: nil

  # The content warning rides the AP `summary`. Mirror it so the Mastodon
  # view can hide the body behind a spoiler (cw drives `spoiler_text` and
  # `sensitive`).
  defp content_warning(%{"summary" => s}) when is_binary(s) and s != "", do: s
  defp content_warning(_), do: nil

  defp insert_note(note_json, account_id, uri) do
    if same_host?(note_json["id"], uri) do
      do_insert_note(note_json, account_id, uri)
    else
      # The origin served a note whose `id` lives on a different host than
      # the URL we fetched — refuse to mirror it under a spoofed ap_id.
      {:error, :id_host_mismatch}
    end
  end

  defp do_insert_note(note_json, account_id, uri) do
    attrs = %{
      "account_id" => account_id,
      "content" => Extract.content_with_title(note_json),
      "title" => Extract.article_title(note_json),
      "ap_id" => uri,
      "visibility" => visibility_from(note_json),
      "cw" => content_warning(note_json),
      "sensitive" => note_json["sensitive"] == true,
      "emojis" => Emojis.from_tag(note_json["tag"]),
      "in_reply_to_ap_id" => extract(note_json["inReplyTo"]),
      "quote_of_ap_id" => quote_uri(note_json),
      "mfm" => mfm_source(note_json)
    }

    %Note{}
    |> Note.changeset(attrs)
    |> Published.stamp(note_json)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :ap_id)
    |> case do
      {:ok, %Note{id: nil}} ->
        # on_conflict :nothing on a hit returns the struct without an id;
        # re-fetch.
        {:ok, Repo.get_by(Note, ap_id: uri)}

      {:ok, %Note{} = n} ->
        MediaIngest.attach(n.id, account_id, note_json["attachment"])
        Polls.ingest_remote_poll(n.id, note_json)
        {:ok, n}

      {:error, _} = err ->
        err
    end
  end

  defp visibility_from(note) do
    to = list(note["to"])
    cc = list(note["cc"])

    cond do
      Enum.any?(to, &public?/1) -> "public"
      Enum.any?(cc, &public?/1) -> "unlisted"
      Enum.any?(to ++ cc, &String.ends_with?(&1 || "", "/followers")) -> "followers"
      true -> "direct"
    end
  end

  defp list(v) when is_list(v), do: v
  defp list(v) when is_binary(v), do: [v]
  defp list(_), do: []

  defp public?(v) when is_binary(v), do: v == @public_ns or v == "Public"
  defp public?(_), do: false

  # True when two AP id/uri values (string or inlined `%{"id" => …}`) share
  # the same host. Case-insensitive; false if either host is missing.
  defp same_host?(a, b) do
    with ua when is_binary(ua) <- extract(a),
         ub when is_binary(ub) <- extract(b),
         %URI{host: ha} when is_binary(ha) and ha != "" <- URI.parse(ua),
         %URI{host: hb} when is_binary(hb) and hb != "" <- URI.parse(ub) do
      String.downcase(ha) == String.downcase(hb)
    else
      _ -> false
    end
  end
end

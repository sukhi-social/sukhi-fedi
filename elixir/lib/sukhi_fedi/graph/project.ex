# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Project do
  @moduledoc """
  Rows of the relational store, written as the ActivityPub JSON the graph
  already understands.

  The graph has one door for a note or an edge (`SukhiFedi.Graph.Activity`).
  What a local user did, and what is already stored, enter by the same door:
  these functions only *say it in ActivityPub*, so there is no second way to
  write a note into the graph. They are pure (rows in, maps out) and never
  touch either database; `SukhiFedi.Graph.Local` fetches the rows and calls
  `Activity.record/2`.

  Activity ids are derived from the row's id, so a row written twice is one
  activity (the graph upserts by id).
  """

  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.Graph.Audience
  alias SukhiFedi.Schema.{Account, Note}

  @doc "The actor's IRI: ours is built, a remote one is as stored. `nil` when unknown."
  @spec actor_iri(Account.t()) :: String.t() | nil
  def actor_iri(%Account{domain: nil} = a), do: ActorJson.actor_uri(a)
  def actor_iri(%Account{actor_uri: uri}) when is_binary(uri), do: uri
  def actor_iri(_), do: nil

  @doc "The author's followers collection."
  @spec followers(Account.t()) :: String.t()
  def followers(%Account{} = a), do: actor_iri(a) <> "/followers"

  @doc """
  The Create/Update of a local note. `kind` is `"Create"` or `"Update"`;
  `media` are the note's `Media` rows, `poll` its `Poll` with options (or nil),
  `at` when the event happened (an Update's own time).
  """
  @spec note_activity(String.t(), Note.t(), Account.t(), [struct()], struct() | nil, DateTime.t()) ::
          map()
  def note_activity(kind, %Note{} = note, %Account{} = author, media, poll, %DateTime{} = at) do
    object = note_object(note, author, media, poll)

    {id, object, published} =
      if kind == "Update",
        do: {note.ap_id <> "#update-#{micros(at)}", Map.put(object, "updated", iso(at)), iso(at)},
        else: {note.ap_id <> "#create", object, object["published"]}

    %{
      "id" => id,
      "type" => kind,
      "actor" => actor_iri(author),
      "published" => published,
      "to" => object["to"],
      "cc" => object["cc"],
      "object" => object
    }
  end

  @doc "The AP object of a local note."
  @spec note_object(Note.t(), Account.t(), [struct()], struct() | nil) :: map()
  def note_object(%Note{} = note, %Account{} = author, media, poll) do
    {to, cc} = audience(note.visibility, followers(author))

    %{
      "id" => note.ap_id,
      "type" => if(poll, do: "Question", else: "Note"),
      "attributedTo" => actor_iri(author),
      "published" => iso(note.created_at),
      "to" => to,
      "cc" => cc,
      "content" => Note.html(note),
      "_misskey_content" => blank(note.mfm),
      "summary" => blank(note.cw),
      "name" => blank(note.title),
      "sensitive" => note.sensitive == true,
      "inReplyTo" => note.in_reply_to_ap_id,
      "attachment" => Enum.map(media, &attachment/1),
      "tag" => Enum.map(note.emojis || [], &emoji_tag/1)
    }
    |> Map.merge(poll_fields(poll))
    |> Map.reject(fn {_, v} -> is_nil(v) or v == [] end)
  end

  @doc "`{to, cc}` for a visibility."
  @spec audience(String.t() | nil, String.t()) :: {[String.t()], [String.t()]}
  def audience("public", followers), do: {[Audience.public()], [followers]}
  def audience("unlisted", followers), do: {[followers], [Audience.public()]}
  def audience(v, followers) when v in ["followers", "private"], do: {[followers], []}
  def audience(_, _), do: {[], []}

  @doc "A Delete of a note we hold the AP id of."
  @spec delete(String.t(), Account.t()) :: map()
  def delete(note_ap_id, %Account{} = actor),
    do: %{
      "id" => note_ap_id <> "#delete",
      "type" => "Delete",
      "actor" => actor_iri(actor),
      "object" => note_ap_id
    }

  @doc """
  A Like (the plain favourite, emoji `⭐`/nil) or an EmojiReact.
  `kind` is the row's own id, so a redelivery is the same activity.
  """
  @spec reaction(map(), Account.t(), String.t(), String.t() | nil, String.t()) :: map()
  def reaction(%{id: id}, %Account{} = actor, note_ap_id, emoji, published) do
    base = %{
      "id" => reaction_id(actor, id),
      "actor" => actor_iri(actor),
      "object" => note_ap_id,
      "published" => published
    }

    if emoji in [nil, "", "⭐"] do
      Map.put(base, "type", "Like")
    else
      base
      |> Map.put("type", "EmojiReact")
      |> Map.put("content", emoji)
      |> Map.merge(custom(emoji))
    end
  end

  @spec reaction_id(Account.t(), integer()) :: String.t()
  def reaction_id(actor, id), do: actor_iri(actor) <> "#reactions/#{id}"

  @spec announce(integer(), Account.t(), String.t(), String.t()) :: map()
  def announce(id, %Account{} = actor, note_ap_id, published),
    do: %{
      "id" => announce_id(actor, id),
      "type" => "Announce",
      "actor" => actor_iri(actor),
      "object" => note_ap_id,
      "published" => published
    }

  @spec announce_id(Account.t(), integer()) :: String.t()
  def announce_id(actor, id), do: actor_iri(actor) <> "#announces/#{id}"

  @spec follow(integer(), String.t(), String.t(), String.t()) :: map()
  def follow(id, follower_iri, followee_iri, published),
    do: %{
      "id" => follow_id(follower_iri, id),
      "type" => "Follow",
      "actor" => follower_iri,
      "object" => followee_iri,
      "published" => published
    }

  @spec follow_id(String.t(), integer()) :: String.t()
  def follow_id(follower_iri, id), do: follower_iri <> "#follows/#{id}"

  @doc "An Undo of an activity we named by id."
  @spec undo(String.t(), String.t(), String.t()) :: map()
  def undo(activity_id, actor_iri, published),
    do: %{
      "id" => activity_id <> "/undo",
      "type" => "Undo",
      "actor" => actor_iri,
      "object" => activity_id,
      "published" => published
    }

  # ------------------------------------------------------------------ parts

  defp attachment(m) do
    %{
      "type" => "Document",
      "url" => m.url,
      "mediaType" => m.type,
      "name" => blank(m.description),
      "blurhash" => m.blurhash,
      "width" => m.width,
      "height" => m.height
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp poll_fields(nil), do: %{}

  defp poll_fields(poll) do
    choices =
      poll.options
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&%{"type" => "Note", "name" => &1.title})

    %{
      if(poll.multiple, do: "anyOf", else: "oneOf") => choices,
      "endTime" => iso(poll.expires_at)
    }
  end

  # `notes.emojis` is the Mastodon shape (shortcode/url); the AP tag is the same thing.
  defp emoji_tag(%{} = e) do
    name = e["shortcode"] || e[:shortcode] || e["name"] || e[:name]
    url = e["url"] || e[:url]

    %{
      "type" => "Emoji",
      "id" => url,
      "name" => ":" <> String.trim(to_string(name), ":") <> ":",
      "icon" => %{"url" => url}
    }
  end

  # A reaction `:name:` is a custom emoji; without its image the IRI is the shortcode.
  defp custom(":" <> _ = emoji) do
    name = String.trim(emoji, ":")
    %{"tag" => [%{"type" => "Emoji", "id" => "urn:emoji:" <> name, "name" => emoji}]}
  end

  defp custom(_), do: %{}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp micros(nil), do: 0
  defp micros(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp micros(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> micros()

  defp blank(s) when is_binary(s) and s != "", do: s
  defp blank(_), do: nil
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Mirror do
  @moduledoc """
  Mirroring remote notes: inbound `Create(Note)` → a `notes` row (with
  tags, media, mention notifications and reference prefetch), and the
  inbound `Delete` that tombstones a mirror again.
  """

  import Ecto.Query

  alias SukhiFedi.AP.Instructions.{Extract, Resolve}
  alias SukhiFedi.AP.{Emojis, MediaIngest, Published}
  alias SukhiFedi.{Notifications, Polls, Repo}
  alias SukhiFedi.Schema.{Account, Note}

  @doc """
  Replay an archived `Create` activity to recreate a remote note that is
  gone from `notes` (lost to a past cascade, not a `Delete`). Same mirror
  path as live ingest, but `notify?: false` so resurrecting an old post
  doesn't fire a "new" mention notification. Public for the archive
  rebuild ([[RebuildFromArchive]]).
  """
  @spec reingest_for_rebuild(map()) :: term()
  def reingest_for_rebuild(activity), do: maybe_mirror_create_note(activity, false)

  @doc """
  Inbound Create(Note) → mirror to the `notes` table so Timelines.home /
  Timelines.public can see it. DMs (no AS#Public in `to`/`cc`) are
  routed by `Instructions.DMs`, which writes its own Note row scoped
  to the local recipient; we skip them here to avoid double-insert.
  """
  def maybe_mirror_create_note(activity, notify? \\ true)

  def maybe_mirror_create_note(
        %{"type" => "Create", "object" => %{"type" => type} = note} = activity,
        notify?
      )
      when type in ["Note", "Article", "Question"] do
    if Extract.dm_addressing?(note) do
      :ok
    else
      ap_id = note["id"]

      attributed_to =
        Extract.extract_uri(note["attributedTo"]) || Extract.extract_uri(activity["actor"])

      # The note's id, its author, and the delivering actor must all live on
      # the same host. This blocks a server from injecting a note under
      # another origin's id (impersonation / ap_id collision), including
      # forging a post attributed to a local user.
      with true <- is_binary(ap_id),
           true <- is_binary(attributed_to),
           # A note id on our own host is never a mirror: the real row
           # already exists locally (with ap_id NULL, so the unique index
           # below can't catch it) or was deliberately deleted. Without
           # this gate our own Create — delivered to a local follower's
           # inbox, or bounced back by a relay — lands as a duplicate row.
           false <- Extract.own_host?(ap_id),
           true <- Extract.same_host?(ap_id, attributed_to),
           true <- Extract.same_host?(attributed_to, activity["actor"]),
           {:ok, %Account{id: account_id}} <- Resolve.resolve_or_ingest_actor(attributed_to) do
        attrs = %{
          "account_id" => account_id,
          "content" => Extract.content_with_title(note),
          "title" => Extract.article_title(note),
          "ap_id" => ap_id,
          "visibility" => Extract.visibility_from(note),
          "cw" => Extract.content_warning(note),
          "sensitive" => note["sensitive"] == true,
          "emojis" => Emojis.from_tag(note["tag"]),
          "in_reply_to_ap_id" => Extract.extract_uri(note["inReplyTo"]),
          "quote_of_ap_id" => Extract.extract_quote_uri(note),
          "mfm" => Extract.extract_mfm(note)
        }

        case %Note{}
             |> Note.changeset(attrs)
             |> Published.stamp(note)
             |> Repo.insert(on_conflict: :nothing, conflict_target: :ap_id) do
          {:ok, %Note{id: nid}} when not is_nil(nid) ->
            SukhiFedi.Tags.upsert_for_note(nid, note["content"])
            MediaIngest.attach(nid, account_id, note["attachment"])
            Polls.ingest_remote_poll(nid, note)
            if notify?, do: notify_mentions(note, nid, account_id)
            # 外から届いた返信を、板に結ぶ。結ばないと板の一覧にも
            # 流れにも出てこない(どちらも `deco_notes` を join する)。
            # 読むたびに親を遡って探すこともできるが、それは頁を開く
            # たびに払う値段になる ── 書き込みの一度で済ませる。
            bind_to_deco(nid, note)
            fetch_referenced_notes(attrs)
            :ok

          _ ->
            :ok
        end
      else
        _ -> :ok
      end
    end
  end

  def maybe_mirror_create_note(_, _), do: :ok

  # deco addon を切ってあるインスタンス(sukhi 本体など)では何もしない。
  defp bind_to_deco(note_id, raw) do
    if SukhiFedi.Addon.Registry.enabled?(:deco) do
      SukhiFedi.Addons.Deco.bind_inbound(note_id, raw)
    end

    :ok
  end

  @doc """
  Inbound `Delete` activity: drop the local mirror of whatever the
  remote actor is tombstoning. Object id can be a string or a Tombstone
  map with `id`. We only honour a Delete whose target note lives on the
  actor's own host — without this, any (signed) server could delete any
  mirrored note by ap_id, regardless of who it belongs to.
  """
  def maybe_handle_delete(%{"type" => "Delete", "actor" => actor_uri, "object" => object})
      when is_binary(actor_uri) do
    with ap_id when is_binary(ap_id) <- Extract.extract_object_id(object),
         true <- Extract.same_host?(ap_id, actor_uri) do
      from(n in Note, where: n.ap_id == ^ap_id) |> Repo.delete_all()
    end

    :ok
  end

  def maybe_handle_delete(_), do: :ok

  @doc """
  Inbound `Update(Question)`: keep a mirrored remote poll's tallies live.
  A poll accrues an `Update` on every vote, so the freshest counts ride
  these. Create the poll if we have the note but missed its poll (notes
  mirrored before poll ingest existed self-heal on the next vote), refresh
  the cached counts if it's already there. Same host binding as Delete —
  only the object's own origin may touch it.
  """
  def maybe_handle_update(%{
        "type" => "Update",
        "actor" => actor_uri,
        "object" => %{"type" => "Question"} = object
      })
      when is_binary(actor_uri) do
    with ap_id when is_binary(ap_id) <- Extract.extract_object_id(object),
         true <- Extract.same_host?(ap_id, actor_uri),
         %Note{id: nid} <- Repo.get_by(Note, ap_id: ap_id) do
      if Polls.has_poll?(nid),
        do: Polls.refresh_remote_poll_counts(nid, object),
        else: Polls.ingest_remote_poll(nid, object)
    end

    :ok
  end

  # Inbound `Update(Note)` / `Update(Article)`: a remote post (or
  # hackers.pub article) was edited. Refresh the mirror's text in place —
  # body (with the Article title re-folded), title column, content
  # warning, sensitivity, custom emoji, MFM source — and re-extract
  # hashtags. We rebuild every field from the incoming object rather than
  # diffing, so the title can't double-prepend. Same host binding as
  # Delete; only the object's own origin may edit it. Attached media and
  # polls are not re-synced on edit.
  def maybe_handle_update(%{
        "type" => "Update",
        "actor" => actor_uri,
        "object" => %{"type" => type} = object
      })
      when is_binary(actor_uri) and type in ["Note", "Article"] do
    with ap_id when is_binary(ap_id) <- Extract.extract_object_id(object),
         true <- Extract.same_host?(ap_id, actor_uri),
         %Note{} = note <- Repo.get_by(Note, ap_id: ap_id) do
      attrs =
        %{
          "content" => Extract.content_with_title(object),
          "title" => Extract.article_title(object),
          "cw" => Extract.content_warning(object),
          "sensitive" => object["sensitive"] == true,
          "emojis" => Emojis.from_tag(object["tag"]),
          "mfm" => Extract.extract_mfm(object)
        }
        |> keep_existing_when_blank_body()

      case note |> Note.changeset(attrs) |> Repo.update() do
        {:ok, %Note{id: nid}} -> SukhiFedi.Tags.upsert_for_note(nid, object["content"])
        _ -> :ok
      end
    end

    :ok
  end

  def maybe_handle_update(_), do: :ok

  # A remote Update with an empty/missing body must not wipe the stored post.
  # content_with_title/1 returns "" when the object carries neither a body nor
  # an Article name; in that case keep the previous content (and its folded
  # title) rather than overwriting with blank. cw/sensitive/emojis/mfm are still
  # rebuilt — clearing those is a legitimate edit; emptying the whole body is
  # not, and the prior version lives only in this row + the archive.
  defp keep_existing_when_blank_body(%{"content" => content} = attrs) do
    if is_binary(content) and String.trim(content) != "" do
      attrs
    else
      attrs |> Map.delete("content") |> Map.delete("title")
    end
  end

  # Best-effort: pull the reply parent and the quoted note so threading
  # (`in_reply_to_id`) and quote rendering resolve to local rows.
  # NoteFetcher checks the DB first, so this only hits the network on a
  # genuine miss; one level only (the fetched note stores its own
  # in_reply_to_ap_id but we don't recurse). Failures are ignored — the
  # reply/quote is already stored, it just won't link until we see the
  # referenced note another way.
  defp fetch_referenced_notes(attrs) do
    for key <- ["in_reply_to_ap_id", "quote_of_ap_id"],
        uri = attrs[key],
        is_binary(uri) do
      # Truly best-effort: the fetch goes over NATS to Bun, so a down /
      # unreachable peer must never fail the inbox write. Swallow both
      # errors and exits (e.g. NATS not connected).
      try do
        SukhiFedi.Federation.NoteFetcher.fetch_and_mirror(uri)
      rescue
        _ -> :error
      catch
        _kind, _reason -> :error
      end
    end

    :ok
  end

  # A mirrored note can name local users in its AP `tag` array. Notify
  # each — this is the `mention` notification type. DM-addressed notes
  # never reach here (routed by `Instructions.DMs`).
  defp notify_mentions(note, note_id, author_id) do
    note
    |> Map.get("tag")
    |> List.wrap()
    |> Enum.each(fn
      %{"type" => "Mention", "href" => href} when is_binary(href) ->
        case Resolve.local_account_id_from_uri(href) do
          nil ->
            :ok

          local_id ->
            Notifications.create(%{
              account_id: local_id,
              from_account_id: author_id,
              note_id: note_id,
              type: "mention"
            })
        end

      _ ->
        :ok
    end)

    :ok
  end
end

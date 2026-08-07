# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Read do
  @moduledoc """
  Reading single notes: visibility rules, the viewer-gated single-note
  load, and the reply/quote/poll enrichment (`with_refs/2`) every
  Mastodon Status render goes through.
  """

  import Ecto.Query

  alias SukhiFedi.Notes.Ids
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, ConversationParticipant, Follow, Note}

  @doc """
  Load a single note by id with the assocs Mastodon Status JSON
  needs: account, media, poll, reactions.

  Viewer-aware: `viewer_id` (the requesting account, or `nil` when
  unauthenticated) must be allowed to see the note's visibility, else
  this returns `{:error, :not_found}` — matching Mastodon, which 404s a
  status the caller isn't authorised to see. Without this, any caller
  could read followers-only and direct (DM) notes by guessing the id.
  """
  @spec get_note(integer() | binary(), integer() | nil) ::
          {:ok, Note.t()} | {:error, :not_found}
  def get_note(id, viewer_id \\ nil) do
    case Ids.parse_int(id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get(Note, n) do
          nil ->
            {:error, :not_found}

          note ->
            if visible_to?(note, viewer_id) do
              {:ok, Repo.preload(note, [:account, :media, :poll, :reactions]) |> with_refs(viewer_id)}
            else
              {:error, :not_found}
            end
        end
    end
  end

  @doc """
  True when `viewer_id` (an account id, or `nil` for an unauthenticated
  request) is permitted to see `note`:

    * `public` / `unlisted` — everyone.
    * own note — the author always sees it.
    * `followers` — accepted local followers of the author.
    * `direct` — participants of the note's conversation.

  The single source of truth for per-note visibility, reused by the
  single-status read, thread context, poll reads/votes and the
  favourite/boost/bookmark interactions.
  """
  @spec visible_to?(Note.t(), integer() | nil) :: boolean()
  def visible_to?(%Note{visibility: v} = note, viewer_id) do
    cond do
      v in SukhiFedi.Visibility.public_only() -> true
      not is_integer(viewer_id) -> false
      note.account_id == viewer_id -> true
      v == "followers" -> local_follower?(viewer_id, note.account_id)
      v == "direct" -> dm_participant?(note, viewer_id)
      true -> false
    end
  end

  def visible_to?(_note, _viewer_id), do: false

  @doc """
  Restrict a `Note` query to the statuses `viewer_id` may see on an
  account's *profile* timeline (`GET /accounts/:id/statuses`):

    * `public` / `unlisted` — always.
    * `followers` — only for the account owner or an accepted local follower.
    * `direct` — never; DMs live in conversations, not on the profile.

  The list-level companion to `visible_to?/2`, so the account-statuses
  endpoint can't enumerate someone's followers-only or direct posts. A
  `nil` viewer (unauthenticated) sees only public/unlisted.
  """
  @spec scope_profile_statuses(Ecto.Query.t(), integer(), integer() | nil) :: Ecto.Query.t()
  def scope_profile_statuses(query, account_id, viewer_id) do
    followers_visible? =
      viewer_id == account_id or
        (is_integer(viewer_id) and local_follower?(viewer_id, account_id))

    allowed =
      if followers_visible?,
        do: SukhiFedi.Visibility.not_direct(),
        else: SukhiFedi.Visibility.public_only()

    query
    |> where([n], n.visibility in ^allowed)
  end

  # An accepted local follow edge from viewer → author. A local follower's
  # `follower_uri` is `https://<domain>/users/<viewer-username>` (same shape
  # the home timeline matches on).
  defp local_follower?(viewer_id, author_id) do
    case Repo.get(Account, viewer_id) do
      %Account{username: u, domain: nil} when is_binary(u) ->
        uri = "https://#{SukhiFedi.Config.domain!()}/users/#{u}"

        Repo.exists?(
          from(f in Follow,
            where:
              f.followee_id == ^author_id and f.follower_uri == ^uri and f.state == "accepted"
          )
        )

      _ ->
        false
    end
  end

  defp dm_participant?(%Note{conversation_ap_id: conv}, viewer_id) when is_binary(conv) do
    Repo.exists?(
      from(cp in ConversationParticipant,
        where: cp.conversation_ap_id == ^conv and cp.account_id == ^viewer_id
      )
    )
  end

  defp dm_participant?(_note, _viewer_id), do: false

  @doc """
  Enrich notes with the reply/quote reference fields the Mastodon view
  needs, resolving the stored AP ids to local rows in one batch query
  (no N+1):

    * `in_reply_to_id` / `in_reply_to_account_id` — the reply parent,
      when we hold it locally *and* `viewer_id` may see it (else left
      nil; the reply still renders). Without the visibility check, a
      reply to a followers-only or direct note exposed its parent's id
      to every viewer — a link that always 404s for anyone who isn't
      an accepted follower (or the DM's other participant), since
      `GET /statuses/:id` correctly gates on the same check this
      skipped.
    * `quoted_note` — the quoted note with its account preloaded, for a
      nested-Status `quote` render. Same visibility gate.

  Accepts a list or a single note; anything else passes through.
  """
  @spec with_refs([Note.t()] | Note.t() | any(), integer() | nil) ::
          [Note.t()] | Note.t() | any()
  def with_refs(notes, viewer_id \\ nil)

  def with_refs(notes, viewer_id) when is_list(notes) do
    refs =
      notes
      |> Enum.flat_map(fn n -> [n.in_reply_to_ap_id, n.quote_of_ap_id] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    by_ap = resolve_refs(refs)
    poll_views = poll_views_for(Enum.map(notes, & &1.id), viewer_id)

    Enum.map(notes, fn n ->
      parent = visible_ref(n.in_reply_to_ap_id, by_ap, viewer_id)
      quoted = visible_ref(n.quote_of_ap_id, by_ap, viewer_id)

      %{
        n
        | in_reply_to_id: parent && parent.id,
          in_reply_to_account_id: parent && parent.account_id,
          quoted_note: quoted,
          poll_view: Map.get(poll_views, n.id)
      }
    end)
  end

  def with_refs(%Note{} = note, viewer_id),
    do: note |> List.wrap() |> with_refs(viewer_id) |> hd()

  def with_refs(other, _viewer_id), do: other

  # For the notes that own a poll (usually none in a given page), build the
  # Mastodon-shaped poll view, keyed by note id. One query finds the polls;
  # the per-poll tally reuse keeps remote-poll handling identical to the
  # single-status path. `viewer_id` nil → no own-vote highlight (public TLs).
  defp poll_views_for([], _viewer_id), do: %{}

  defp poll_views_for(note_ids, viewer_id) do
    from(p in SukhiFedi.Schema.Poll, where: p.note_id in ^note_ids, select: {p.note_id, p.id})
    |> Repo.all()
    |> Map.new(fn {note_id, poll_id} ->
      case SukhiFedi.Polls.get_with_results(poll_id, viewer_id) do
        {:ok, view} -> {note_id, view}
        _ -> {note_id, nil}
      end
    end)
  end

  # Look up a resolved ref and gate it on the viewer's ability to see it.
  # `resolve_refs/1` only checks "do we hold this row locally" — it has
  # no idea who's asking, so a followers-only or DM parent came back
  # exposed to everyone. This is the one place that turns "exists" into
  # "exists, and you're allowed to know that."
  defp visible_ref(nil, _by_ap, _viewer_id), do: nil

  defp visible_ref(ap_id, by_ap, viewer_id) do
    case Map.get(by_ap, ap_id) do
      nil ->
        nil

      note ->
        ok? = visible_to?(note, viewer_id)
        require Logger
        Logger.warning("DEBUG visible_ref: note_id=#{note.id} vis=#{note.visibility} viewer_id=#{inspect(viewer_id)} visible?=#{ok?}")
        if ok?, do: note, else: nil
    end
  end

  # Resolve each ref URI to its local Note (account preloaded), keyed by
  # the URI string the caller holds. A ref is either a remote `ap_id` or
  # one of our synthesized local note URLs (whose row has a NULL `ap_id`),
  # so match remote refs by `ap_id` and local ones by the id in the URL —
  # otherwise a reply/quote whose parent is local never resolves.
  defp resolve_refs([]), do: %{}

  defp resolve_refs(refs) do
    {local_pairs, remote_uris} =
      Enum.reduce(refs, {[], []}, fn uri, {locals, remotes} ->
        case Ids.local_note_id_from_uri(uri) do
          nil -> {locals, [uri | remotes]}
          id -> {[{id, uri} | locals], remotes}
        end
      end)

    remote_map =
      if remote_uris == [] do
        %{}
      else
        from(n in Note, where: n.ap_id in ^remote_uris)
        |> Repo.all()
        |> Repo.preload(:account)
        |> Map.new(fn n -> {n.ap_id, n} end)
      end

    local_ids = Enum.map(local_pairs, fn {id, _uri} -> id end)

    local_rows =
      if local_ids == [] do
        %{}
      else
        from(n in Note, where: n.id in ^local_ids)
        |> Repo.all()
        |> Repo.preload(:account)
        |> Map.new(fn n -> {n.id, n} end)
      end

    # Re-key the local rows by the synthesized URL the caller looks up with;
    # drop any whose note id no longer exists (e.g. deleted parent).
    local_map =
      local_pairs
      |> Enum.flat_map(fn {id, uri} ->
        case Map.get(local_rows, id) do
          nil -> []
          n -> [{uri, n}]
        end
      end)
      |> Map.new()

    Map.merge(remote_map, local_map)
  end
end

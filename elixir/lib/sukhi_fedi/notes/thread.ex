# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Thread do
  @moduledoc """
  Thread context: walking a note's ancestors (with best-effort remote
  backfill) and descendants for the Mastodon `/context` endpoint.
  """

  import Ecto.Query

  alias SukhiFedi.Notes.{Ids, Read}
  alias SukhiFedi.{Accounts, Repo}
  alias SukhiFedi.Schema.Note

  @max_depth 60

  # How many missing ancestors to backfill from the origin per context
  # view. The walk is bounded by @max_depth; this separately caps the
  # number of synchronous remote fetches so opening one note can't fan
  # out into dozens of round-trips.
  @ancestor_backfill 20

  @doc """
  Build a Mastodon Context for a note: ancestors (parents up the
  reply chain) and descendants (replies down the tree). Capped at
  depth #{@max_depth} like Mastodon.

  Ancestors are backfilled on demand: walking up `in_reply_to_ap_id`,
  a parent we don't hold locally is fetched + mirrored via
  `Federation.NoteFetcher` (best-effort, up to #{@ancestor_backfill}
  fetches) so a reply opened in isolation still shows its thread.
  Descendants stay local-only — pulling a remote `replies` collection
  is a separate piece.
  """
  @spec context(integer() | binary(), integer() | nil) ::
          {:ok, %{ancestors: [Note.t()], descendants: [Note.t()]}} | {:error, :not_found}
  def context(note_id, viewer_id \\ nil) do
    case Ids.parse_int(note_id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get(Note, n) do
          nil ->
            {:error, :not_found}

          note ->
            if Read.visible_to?(note, viewer_id) do
              note = Repo.preload(note, account: &Accounts.by_ids/1)

              # Filter every thread node by the viewer's visibility too, so a
              # private ancestor/descendant from another user can't leak via
              # the root note's context.
              {:ok,
               %{
                 ancestors:
                   note
                   |> ancestors_of()
                   |> Enum.filter(&Read.visible_to?(&1, viewer_id))
                   |> Read.with_refs(viewer_id),
                 descendants:
                   note
                   |> descendants_of()
                   |> Enum.filter(&Read.visible_to?(&1, viewer_id))
                   |> Read.with_refs(viewer_id)
               }}
            else
              {:error, :not_found}
            end
        end
    end
  end

  defp ancestors_of(%Note{in_reply_to_ap_id: nil}), do: []

  defp ancestors_of(%Note{in_reply_to_ap_id: parent_ap_id}) do
    walk_ancestors(parent_ap_id, [], 0, @ancestor_backfill)
  end

  # `acc` is built by prepending each note as we climb, so the furthest
  # ancestor (the root) ends up at the head — already the oldest-first
  # order Mastodon wants. Return it as-is; don't reverse.
  defp walk_ancestors(_ap_id, acc, depth, _budget) when depth >= @max_depth,
    do: acc

  defp walk_ancestors(nil, acc, _depth, _budget), do: acc

  defp walk_ancestors(ap_id, acc, depth, budget) do
    case lookup_note_by_uri(ap_id) do
      %Note{} = note ->
        walk_ancestors(note.in_reply_to_ap_id, [note | acc], depth + 1, budget)

      nil ->
        # A local parent (its `ap_id` is NULL) resolves above by id, so a
        # miss is a remote ancestor we haven't mirrored — pull it from the
        # origin. Never federate-fetch one of our own URLs; a miss ends it.
        if budget > 0 and is_nil(Ids.local_note_id_from_uri(ap_id)) do
          case fetch_ancestor(ap_id) do
            %Note{} = note ->
              walk_ancestors(note.in_reply_to_ap_id, [note | acc], depth + 1, budget - 1)

            nil ->
              acc
          end
        else
          acc
        end
    end
  end

  # Best-effort backfill of one ancestor. The fetch goes over NATS to Bun;
  # a down peer / disconnected NATS must never crash the context read.
  defp fetch_ancestor(ap_id) do
    try do
      case SukhiFedi.Federation.NoteFetcher.fetch_and_mirror(ap_id) do
        {:ok, %Note{} = n} -> Repo.preload(n, [:media, account: &Accounts.by_ids/1])
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _kind, _reason -> nil
    end
  end

  defp descendants_of(note) do
    case Ids.local_note_ap_id(note) do
      nil -> []
      ap_id -> walk_descendants([ap_id], [], 0)
    end
  end

  defp walk_descendants(_frontier, acc, depth) when depth >= @max_depth, do: Enum.reverse(acc)
  defp walk_descendants([], acc, _depth), do: Enum.reverse(acc)

  defp walk_descendants(frontier, acc, depth) do
    children =
      from(n in Note,
        where: n.in_reply_to_ap_id in ^frontier,
        order_by: [asc: n.id],
        preload: [:media, account: ^(&Accounts.by_ids/1)]
      )
      |> Repo.all()

    case children do
      [] ->
        Enum.reverse(acc)

      _ ->
        next_frontier = Enum.map(children, &Ids.local_note_ap_id/1) |> Enum.reject(&is_nil/1)
        walk_descendants(next_frontier, Enum.reverse(children, acc), depth + 1)
    end
  end

  # Resolve a note by an AP URL that may be one of our own synthesized
  # local ids (`https://<domain>/users/<u>/notes/<id>`, whose row carries
  # a NULL `ap_id`) or a real remote `ap_id`.
  defp lookup_note_by_uri(uri) do
    query =
      case Ids.local_note_id_from_uri(uri) do
        nil -> from(n in Note, where: n.ap_id == ^uri)
        id -> from(n in Note, where: n.id == ^id)
      end

    Repo.one(from(n in query, preload: [:media, account: ^(&Accounts.by_ids/1)]))
  end
end

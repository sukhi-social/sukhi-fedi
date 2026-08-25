# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes do
  @moduledoc """
  Notes context. Reachable from the api plugin node via
  `SukhiApi.GatewayRpc.call(SukhiFedi.Notes, :fun, [args])`.

  This module is the stable public surface — every function name and
  arity callers (and the RPC bridge) rely on lives here. The work is
  done in the submodules, one per concern:

    * `Notes.Create`       — creating + deleting notes (statuses, DMs,
      polls, media, reply/quote resolution)
    * `Notes.Read`         — single-note read, visibility rules, ref
      enrichment (`with_refs/2`)
    * `Notes.Thread`       — ancestors/descendants for `/context`
    * `Notes.Interactions` — favourite / reaction / reblog / bookmark /
      pin + the viewer's lists
    * `Notes.Counts`       — interaction counts, reaction breakdowns,
      viewer flags
    * `Notes.Ids`          — note ids ⇄ AP URLs (local notes carry no
      `ap_id`; it's synthesized on demand)
  """

  import Ecto.Query

  alias SukhiFedi.Notes.{Counts, Create, Interactions, Read, Thread, Parents}
  alias SukhiFedi.Schema.Note

  # ── origin ───────────────────────────────────────────────────────────────

  @doc """
  Compose an origin filter onto a `Note` query. Locality lives in
  `notes.domain` (NULL = local, a host = remote), mirroring the author's
  `accounts.domain` — set at write time from the ap_id host. (It used to be
  read off `ap_id IS NULL`, but local notes now carry an ap_id too.) Shared
  by the public/tag timeline's local filter and the remote wipe/rebuild
  tooling so there's a single definition of origin.
  """
  @spec local_notes(Ecto.Queryable.t()) :: Ecto.Query.t()
  def local_notes(query \\ Note), do: from(n in query, where: is_nil(n.domain))

  @spec remote_notes(Ecto.Queryable.t()) :: Ecto.Query.t()
  def remote_notes(query \\ Note), do: from(n in query, where: not is_nil(n.domain))

  # ── create / delete ──────────────────────────────────────────────────────

  defdelegate create_note(attrs), to: Create
  defdelegate create_status(account, params), to: Create
  defdelegate delete_note(account, note_id), to: Create
  defdelegate enqueue_update(note_id), to: Create

  # ── reads ────────────────────────────────────────────────────────────────

  defdelegate get_note(id, viewer_id \\ nil), to: Read
  defdelegate visible_to?(note, viewer_id), to: Read
  defdelegate scope_profile_statuses(query, account_id, viewer_id), to: Read
  defdelegate with_refs(notes, viewer_id \\ nil), to: Read

  # ── context (ancestors / descendants) ────────────────────────────────────

  defdelegate context(note_id, viewer_id \\ nil), to: Thread

  # ── interactions: favourite / reblog / bookmark / pin ────────────────────

  defdelegate favourite_emoji(), to: Interactions
  defdelegate favourite(account, note_id), to: Interactions
  defdelegate unfavourite(account, note_id), to: Interactions
  defdelegate react(account, note_id, emoji), to: Interactions
  defdelegate unreact(account, note_id, emoji), to: Interactions
  defdelegate reblog(account, note_id), to: Interactions
  defdelegate unreblog(account, note_id), to: Interactions
  defdelegate bookmark(account, note_id), to: Interactions
  defdelegate unbookmark(account, note_id), to: Interactions
  defdelegate pin(account, note_id), to: Interactions
  defdelegate unpin(account, note_id), to: Interactions
  defdelegate list_bookmarks(account, opts), to: Interactions
  defdelegate list_favourites(account, opts), to: Interactions

  # ── counts + viewer flags ────────────────────────────────────────────────

  defdelegate counts_for_note(note_id), to: Counts
  defdelegate counts_for_notes(note_ids), to: Counts
  defdelegate reactions_for_notes(note_ids, viewer_id \\ nil), to: Counts

  # 平らに並べる面が返信へ添える、親の一行（`Notes.Parents`）。
  defdelegate parents_for_notes(note_ids), to: Parents, as: :for_note_ids
  defdelegate parents_by_ap_id(ap_ids), to: Parents, as: :by_ap_id
  defdelegate viewer_flags(account_id, note_id), to: Counts
  defdelegate viewer_flags_many(account_id, note_ids), to: Counts
end

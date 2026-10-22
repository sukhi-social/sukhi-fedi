# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.WipeRemote do
  @moduledoc """
  Wipe mirrored remote-origin notes so they can be rebuilt from scratch —
  the "external data is a reconstructible cache" half of keeping external
  and internal data separate. Use it when a peer fed us bad note data and
  the cleanest fix is to drop the mirror and re-mirror it.

  Scope is strictly remote notes (`ap_id IS NOT NULL`, via
  `SukhiFedi.Notes.remote_notes/1`). A local note carries no `ap_id`, so
  this can never touch one. Pass `domain: "peer.example"` to reset just one
  server's notes instead of every remote note.

  Deleting a note cascades to its dependent rows through the existing
  foreign keys — boosts, bookmarks, reactions, pinned, note_tags,
  note_media, notifications and poll rows are `on_delete: :delete_all`;
  `reports.note_id` is `:nilify_all`. **Accounts and follow edges are not
  touched**, so local follow relationships survive the wipe. Remote actor
  shadows are corrected separately with `RefetchActors` (in-place update),
  not here — they're protected by a `RESTRICT` on `follows.followee_id`
  anyway.

  Two honest caveats, both surfaced by `run(:dry_run)`:

    * A *local* user's reaction / boost / bookmark of a remote note
      references that note, so it cascades away with it. After a rebuild the
      note returns under a fresh id, so such a local interaction couldn't
      have been carried across regardless. Accepted for a personal instance.
    * Rebuild only restores notes the archive (or the origin) still has. A
      remote note that was never archived to `inbound` and whose origin is
      now gone would not come back. So this is a reset of the *cache*, not a
      lossless round-trip — read the dry-run before executing.

  Run on the live gateway, dry-run first, then rebuild:

      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.WipeRemote.run(:dry_run)'
      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.WipeRemote.run(:execute)'
      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:execute)'

  Scope to one peer:

      bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.WipeRemote.run(:dry_run, domain: "peer.example")'
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.Maintenance.{Progress, RebuildRemoteNotes}
  alias SukhiFedi.{Notes, Repo}
  alias SukhiFedi.Schema.{Account, Note}

  @spec run(:dry_run | :execute, keyword()) :: map()
  def run(mode \\ :dry_run, opts \\ []) do
    domain = opts[:domain]
    scope = scope(domain)
    count = Repo.aggregate(scope, :count, :id)
    # Every (table, column) that cascades when a notes row goes — read from
    # the catalog so a table added later is reported, not silently missed.
    cascades = RebuildRemoteNotes.note_fk_refs()

    Logger.info(
      "wipe_remote: mode=#{mode}, domain=#{domain || "(all)"}, " <>
        "remote_notes=#{count}, cascades=#{inspect(cascades)}"
    )

    case mode do
      :dry_run ->
        %{mode: :dry_run, domain: domain, remote_notes: count, cascades: cascades}

      :execute ->
        # One statement, so there is no mid-way count to report; the run row
        # still tells the admin page "this is happening" while it executes.
        %{deleted: deleted} =
          Progress.track("wipe_remote", mode, count, "deleting", fn run ->
            {deleted, _} = Repo.delete_all(scope)
            {%{deleted: deleted}, %{run | done: deleted}}
          end)

        Logger.info("wipe_remote done: deleted #{deleted} remote note(s)")
        %{mode: :execute, domain: domain, deleted: deleted, cascades: cascades}
    end
  end

  defp scope(nil), do: Notes.remote_notes(Note)

  defp scope(domain) when is_binary(domain) do
    account_ids = from(a in Account, where: a.domain == ^domain, select: a.id)
    from(n in Notes.remote_notes(Note), where: n.account_id in subquery(account_ids))
  end
end

# One-shot: delete every Note owned by the default `@watcher` account
# (aggregate summaries) via the standard Notes.delete_note path, so each
# removal fans out as a Delete(Note), then publish one fresh summary.
#
#   bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("resync_default_watcher_summary")'
import Ecto.Query, only: [from: 2]

alias SukhiFedi.{Repo, Notes}
alias SukhiFedi.Addons.NodeinfoMonitor
alias SukhiFedi.Schema.{Account, Note}

case SukhiFedi.Accounts.by_local_username("watcher") do
  nil ->
    :no_default_watcher

  %Account{id: account_id} ->
    deleted =
      from(n in Note, where: n.account_id == ^account_id, select: n.id)
      |> Repo.all()
      |> Enum.map(fn note_id ->
        {note_id, Notes.delete_note(account_id, note_id) |> elem(0)}
      end)

    {:deleted, deleted, NodeinfoMonitor.publish_summary_to_default_watcher()}
end

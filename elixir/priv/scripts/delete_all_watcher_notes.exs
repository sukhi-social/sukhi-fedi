# One-shot: delete every Note owned by a watcher bot via the standard
# Notes.delete_note path, so each removal fans out as a proper Delete(Note)
# to federation instead of vanishing silently. Useful when republishing
# watcher notes after a translator fix -- the old ghost copies on remote
# timelines need a Delete to clear first.
#
#   bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("delete_all_watcher_notes")'
import Ecto.Query, only: [from: 2]

alias SukhiFedi.{Repo, Notes}
alias SukhiFedi.Schema.{Account, Note}

Repo.all(
  from(n in Note,
    join: a in Account,
    on: a.id == n.account_id,
    where: not is_nil(a.monitored_domain),
    select: {a.id, n.id}
  )
)
|> Enum.map(fn {account_id, note_id} ->
  Notes.delete_note(account_id, note_id) |> elem(0) |> then(&{note_id, &1})
end)

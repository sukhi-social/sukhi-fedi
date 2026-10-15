# One-shot: enqueue an outbox backfill for every accepted remote follow.
#
# The backfill normally runs when a new follow is accepted
# (`AP.Instructions.maybe_handle_follow_accept/1`), and a restart already
# re-pends the untouched ones on its own
# (`Federation.OutboxBackfill.pending_existing/0`). This is the manual
# version for when you don't want to wait for a restart.
#
# Rows are inserted straight into `oban_jobs` (not via `Oban.insert/2`), so
# this runs from a plain `eval` with only the Repo started -- the running
# gateway's `:backfill` queue picks them up. Running it twice is harmless:
# the mirror is idempotent on `ap_id`, so duplicate jobs just re-read the
# same outbox.
#
#   bin/combined eval 'SukhiFedi.Release.run_script("backfill_followed_outboxes")'
import Ecto.Query, only: [from: 2]

alias SukhiFedi.Repo
alias SukhiFedi.Schema.{Account, Follow}

from(f in Follow,
  join: a in Account,
  on: a.id == f.followee_id,
  where: f.state == "accepted" and not is_nil(a.domain) and not is_nil(a.actor_uri),
  distinct: a.id,
  select: a.actor_uri
)
|> Repo.all()
|> Enum.map(fn actor_uri ->
  SukhiFedi.Federation.OutboxBackfill.mark_pending(actor_uri)

  %{"actor_uri" => actor_uri}
  |> SukhiFedi.Federation.OutboxBackfill.new()
  |> Repo.insert()
end)

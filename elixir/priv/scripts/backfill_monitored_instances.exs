# One-shot: insert a `monitored_instances` row for every existing watcher
# `Account` that doesn't have one yet. Safe to run multiple times (no-op on
# conflict).
#
#   bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("backfill_monitored_instances")'
import Ecto.Query, only: [from: 2]

alias SukhiFedi.Repo
alias SukhiFedi.Schema.{Account, MonitoredInstance}

from(a in Account, where: not is_nil(a.monitored_domain))
|> Repo.all()
|> Enum.map(fn a ->
  %MonitoredInstance{}
  |> MonitoredInstance.changeset(%{domain: a.monitored_domain, actor_id: a.id})
  |> Repo.insert(on_conflict: :nothing, conflict_target: :domain)
end)

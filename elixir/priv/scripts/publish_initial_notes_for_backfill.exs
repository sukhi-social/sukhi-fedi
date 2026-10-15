# One-shot: for every `MonitoredInstance` that already has at least one
# snapshot, publish an "監視を始めました" Note using the latest snapshot.
# Use after `backfill_monitored_instances` on a deployment where the initial
# polls already ran through PollWorker's old :initial branch (pre-v0.1.22),
# which recorded snapshots but did not publish.
#
#   bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("publish_initial_notes_for_backfill")'
import Ecto.Query, only: [from: 2]

alias SukhiFedi.Repo
alias SukhiFedi.Addons.NodeinfoMonitor
alias SukhiFedi.Schema.{MonitoredInstance, NodeinfoSnapshot}

per_instance =
  from(m in MonitoredInstance, order_by: [asc: m.domain])
  |> Repo.all()
  |> Enum.map(fn mi ->
    snap =
      from(s in NodeinfoSnapshot,
        where: s.monitored_instance_id == ^mi.id,
        order_by: [desc: s.polled_at],
        limit: 1
      )
      |> Repo.one()

    if snap do
      NodeinfoMonitor.publish_initial_note(
        mi,
        %{software_name: snap.software_name, version: snap.version},
        summary?: false
      )
      |> case do
        {:ok, _note} -> {mi.domain, :ok}
        other -> {mi.domain, other}
      end
    else
      {mi.domain, :no_snapshot}
    end
  end)

# Fire the @watcher aggregate exactly once after all per-instance posts land,
# instead of N times from inside the loop.
NodeinfoMonitor.publish_summary_to_default_watcher()

per_instance

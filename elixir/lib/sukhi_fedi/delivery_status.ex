# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.DeliveryStatus do
  @moduledoc """
  How far a post's trip to the rest of the fediverse has got, in three
  words and no more:

    * `:delivering` — still on its way: queued or being sent;
    * `:delivered` — nothing is waiting any more;
    * `:delayed` — some part of the trip is late: a send is being retried
      or has been given up on.

  Alongside it, a stage for a small timeline — received, signing, queued,
  sending (with a rough percent), done — and nothing finer.

  That is the whole answer. Which servers, and how many of them, are
  deliberately not part of it: the author is told "it is on its way / it
  has arrived / it is late", not who is behind it. Nothing in this
  module's result can carry a host or a count, so no caller can leak one
  by accident — the three words and a rough percent are the boundary.

  It is read from what the pipeline already writes, in one batch for any
  number of notes (three grouped queries, never one per note):

    1. the `outbox` row of the note's `created` / `deleted` event
       (`pending` → still to be handed to the delivery node);
    2. the dispatch job for that row (`SukhiDelivery.Outbox.DispatchWorker`),
       which turns the event into one send per inbox;
    3. those sends (`SukhiDelivery.Delivery.Worker`, found by the
       activity id).

  Posts that went by Pull Federation instead of a POST have nothing to
  track here: the activity is in the pull log as soon as the dispatch job
  finishes, and from then on it counts as delivered.

  Only the author may be shown this (the caller decides), and only for a
  while: after `window_days/0` days the answer is `nil`, because the jobs
  it is read from are pruned and an old post has nothing to say.
  """

  import Ecto.Query

  alias SukhiFedi.Repo

  @type state :: :delivering | :delivered | :delayed
  @type kind :: :created | :deleted
  @type stage :: :received | :signing | :queued | :sending | :done

  @window_days 2

  @dispatch_worker "SukhiDelivery.Outbox.DispatchWorker"
  @send_worker "SukhiDelivery.Delivery.Worker"

  @subjects %{
    created: "sns.outbox.note.created",
    deleted: "sns.outbox.note.deleted"
  }
  @deleted_subject @subjects.deleted

  @doc "How long a post's delivery state is reported, in days."
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc """
  The state of each of `account_id`'s own notes among `note_ids`, as
  `%{note_id => %{state:, stage:, percent:}}` (see `progress/3`). Notes that are not the account's, not local, or
  older than the window are left out, so the result can be handed straight
  to a renderer: a missing key means "show nothing".
  """
  @spec for_own_notes(integer() | nil, [integer()], DateTime.t()) :: %{integer() => map()}
  def for_own_notes(account_id, note_ids, now \\ DateTime.utc_now())
  def for_own_notes(nil, _note_ids, _now), do: %{}
  def for_own_notes(_account_id, [], _now), do: %{}

  def for_own_notes(account_id, note_ids, now) when is_integer(account_id) do
    since = DateTime.add(now, -@window_days * 86_400, :second)

    notes =
      from(n in "notes",
        where:
          n.id in ^note_ids and n.account_id == ^account_id and not is_nil(n.ap_id) and
            n.created_at > ^since,
        select: {n.id, n.ap_id}
      )
      |> Repo.all()

    ids = Enum.map(notes, &elem(&1, 0))
    activity_ids = Map.new(notes, fn {id, ap_id} -> {id, ap_id <> "/activity"} end)

    states(:created, ids, activity_ids)
  end

  @doc """
  The state of the `Delete` that went out for `note_ids` (the notes are
  already gone from the database, so this reads only the pipeline). Call it
  for notes the caller has just deleted for their owner; it does not check
  ownership, which `Notes.delete_note/2` already did.
  """
  @spec for_deleted_notes([integer()]) :: %{integer() => map()}
  def for_deleted_notes([]), do: %{}

  def for_deleted_notes(note_ids) do
    ap_ids =
      from(o in "outbox",
        where:
          o.subject == ^@deleted_subject and o.aggregate_type == "note" and
            o.aggregate_id in ^Enum.map(note_ids, &to_string/1),
        select: {o.aggregate_id, fragment("?->>'ap_id'", o.payload)}
      )
      |> Repo.all()
      |> Map.new(fn {aggregate_id, ap_id} -> {String.to_integer(aggregate_id), ap_id} end)

    activity_ids =
      for {id, ap_id} <- ap_ids, is_binary(ap_id), into: %{}, do: {id, ap_id <> "#delete"}

    states(:deleted, Map.keys(activity_ids), activity_ids)
  end

  defp states(_kind, [], _activity_ids), do: %{}

  defp states(kind, ids, activity_ids) do
    events = events(kind, ids)
    dispatches = dispatches(Enum.map(events, fn {_id, {outbox_id, _}} -> outbox_id end))
    sends = sends(Map.values(activity_ids))

    Map.new(ids, fn id ->
      {outbox_id, outbox_status} = Map.get(events, id, {nil, nil})

      {id,
       progress(
         outbox_status,
         Map.get(dispatches, outbox_id, %{}),
         Map.get(sends, activity_ids[id], %{})
       )}
    end)
  end

  @doc """
  Fold what was seen for one post into `%{state:, stage:, percent:}`.

  `outbox_status` is the event row's status (nil when there is none);
  `dispatch` and `sends` are `%{oban_state => how many jobs}` for the
  dispatch job and for the sends over every inbox. The counts go in and
  only a coarse picture comes out: `percent` is the share of sends that
  finished, in steps of 10, and only while `stage` is `:sending`.
  """
  @spec progress(String.t() | nil, %{String.t() => pos_integer()}, %{String.t() => pos_integer()}) ::
          %{state: state(), stage: stage(), percent: 0..100 | nil}
  def progress(outbox_status, dispatch, sends) do
    signals =
      List.wrap(outbox_status && outbox_signal(outbox_status)) ++
        signals(dispatch) ++ signals(sends)

    total = sends |> Map.values() |> Enum.sum()
    done = count(sends, ~w(completed cancelled))

    stage =
      cond do
        total > 0 and done == total -> :done
        total > 0 and (done > 0 or count(sends, ~w(executing retryable discarded)) > 0) -> :sending
        total > 0 -> :queued
        count(dispatch, ~w(executing)) > 0 -> :signing
        outbox_status in ["pending", "failed"] -> :received
        count(dispatch, ~w(available scheduled retryable discarded)) > 0 -> :received
        true -> :done
      end

    %{state: classify(signals), stage: stage, percent: percent(stage, done, total)}
  end

  defp percent(:done, _done, _total), do: 100
  defp percent(:sending, done, total), do: min(div(done * 10 + div(total, 2), total) * 10, 90)
  defp percent(_stage, _done, _total), do: nil

  defp count(by_state, states), do: by_state |> Map.take(states) |> Map.values() |> Enum.sum()

  defp signals(by_state), do: by_state |> Map.keys() |> Enum.map(&job_signal/1)

  @doc """
  Fold the signals seen for one post into its state. A signal is
  `:active` (work is queued or running), `:late` (a retry is waiting or the
  job gave up) or `:done`. Late beats active beats done; no signal at all
  means nothing is waiting, which is delivered.
  """
  @spec classify([:active | :late | :done]) :: state()
  def classify(signals) do
    cond do
      :late in signals -> :delayed
      :active in signals -> :delivering
      true -> :delivered
    end
  end

  @doc false
  # An oban_jobs state, as one of the three signals.
  @spec job_signal(String.t()) :: :active | :late | :done
  def job_signal(state) when state in ~w(available scheduled executing), do: :active
  def job_signal(state) when state in ~w(retryable discarded), do: :late
  def job_signal(_completed_or_cancelled), do: :done

  defp outbox_signal("pending"), do: :active
  defp outbox_signal("failed"), do: :late
  defp outbox_signal(_published), do: :done

  # note_id => {outbox row id, outbox status}; the newest row wins, so a
  # re-emitted event is judged by its latest attempt.
  defp events(kind, ids) do
    from(o in "outbox",
      where:
        o.subject == ^Map.fetch!(@subjects, kind) and o.aggregate_type == "note" and
          o.aggregate_id in ^Enum.map(ids, &to_string/1),
      order_by: [asc: o.id],
      select: {o.aggregate_id, o.id, o.status}
    )
    |> Repo.all()
    |> Map.new(fn {aggregate_id, id, status} ->
      {String.to_integer(aggregate_id), {id, status}}
    end)
  end

  # outbox row id => %{oban_state => jobs} for its dispatch job.
  defp dispatches([]), do: %{}

  defp dispatches(outbox_ids) do
    from(j in "oban_jobs",
      where:
        j.worker == ^@dispatch_worker and
          fragment("CAST(?->>'outbox_id' AS TEXT)", j.args) in ^Enum.map(outbox_ids, &to_string/1),
      group_by: [fragment("CAST(?->>'outbox_id' AS TEXT)", j.args), j.state],
      select: {fragment("CAST(?->>'outbox_id' AS TEXT)", j.args), j.state, count(j.id)}
    )
    |> counts_by_key(&String.to_integer/1)
  end

  # activity id => %{oban_state => jobs}, over every inbox. Which inbox a
  # job was for is dropped here (the query groups on state alone) and
  # never leaves the function.
  defp sends([]), do: %{}

  defp sends(activity_ids) do
    from(j in "oban_jobs",
      where:
        j.worker == ^@send_worker and
          fragment("CAST(?->>'activity_id' AS TEXT)", j.args) in ^activity_ids,
      group_by: [fragment("CAST(?->>'activity_id' AS TEXT)", j.args), j.state],
      select: {fragment("CAST(?->>'activity_id' AS TEXT)", j.args), j.state, count(j.id)}
    )
    |> counts_by_key(& &1)
  end

  # Jobs live in Postgres, plus any extra queue store configured under
  # `:extra_job_repos` (the SQLite delivery queue in a combined release).
  # Counts for the same state are added across stores.
  defp counts_by_key(query, key_fun) do
    SukhiFedi.Queue.job_repos()
    |> Enum.flat_map(& &1.all(query))
    |> Enum.group_by(fn {key, _state, _n} -> key_fun.(key) end, fn {_key, state, n} ->
      {state, n}
    end)
    |> Map.new(fn {key, pairs} ->
      {key, Enum.reduce(pairs, %{}, fn {state, n}, acc -> Map.update(acc, state, n, &(&1 + n)) end)}
    end)
  end
end

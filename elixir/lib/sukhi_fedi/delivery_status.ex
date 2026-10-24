# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.DeliveryStatus do
  @moduledoc """
  How far a post's trip to the rest of the fediverse has got, in three
  words and no more:

    * `:delivering` — still on its way: queued or being sent;
    * `:delivered` — nothing is waiting any more;
    * `:delayed` — some part of the trip is late: a send is being retried
      or has been given up on.

  That is the whole answer. Which servers, and how many of them, are
  deliberately not part of it: the author is told "it is on its way / it
  has arrived / it is late", not who is behind it. Nothing in this
  module's result can carry a host or a count, so no caller can leak one
  by accident — the three words are the boundary.

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
  `%{note_id => state}`. Notes that are not the account's, not local, or
  older than the window are left out, so the result can be handed straight
  to a renderer: a missing key means "show nothing".
  """
  @spec for_own_notes(integer() | nil, [integer()], DateTime.t()) :: %{integer() => state()}
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
  @spec for_deleted_notes([integer()]) :: %{integer() => state()}
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
      outbox = Map.get(events, id)

      outbox_signals =
        case outbox do
          {outbox_id, status} -> [outbox_signal(status) | Map.get(dispatches, outbox_id, [])]
          nil -> []
        end

      {id, classify(outbox_signals ++ Map.get(sends, activity_ids[id], []))}
    end)
  end

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

  # outbox row id => the signals of its dispatch jobs.
  defp dispatches([]), do: %{}

  defp dispatches(outbox_ids) do
    from(j in "oban_jobs",
      where:
        j.worker == ^@dispatch_worker and
          fragment("?->>'outbox_id'", j.args) in ^Enum.map(outbox_ids, &to_string/1),
      group_by: [fragment("?->>'outbox_id'", j.args), j.state],
      select: {fragment("?->>'outbox_id'", j.args), j.state}
    )
    |> signals_by_key(&String.to_integer/1)
  end

  # activity id => the signals of its sends, over every inbox. Which inbox
  # a signal came from is dropped here (the query groups on state alone)
  # and never leaves the function.
  defp sends([]), do: %{}

  defp sends(activity_ids) do
    from(j in "oban_jobs",
      where:
        j.worker == ^@send_worker and
          fragment("?->>'activity_id'", j.args) in ^activity_ids,
      group_by: [fragment("?->>'activity_id'", j.args), j.state],
      select: {fragment("?->>'activity_id'", j.args), j.state}
    )
    |> signals_by_key(& &1)
  end

  defp signals_by_key(query, key_fun) do
    query
    |> Repo.all()
    |> Enum.group_by(fn {key, _state} -> key_fun.(key) end, fn {_key, state} ->
      job_signal(state)
    end)
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Polls do
  @moduledoc """
  Poll reads + vote writes.

  Polls are owned by a Note (1:1). Each Poll has `options` (ordered)
  and `votes` (joined to an option). `multiple == false` constrains
  the caller to one option per vote.

  `vote/3` is idempotent on (account_id, poll_id, option_id). On the
  first insert for a multi-option poll it inserts all chosen options;
  for single-choice polls callers must pass exactly one option index.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.Outbox
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Poll, PollOption, PollVote}

  @doc "Whether a note already owns a poll (used by the archive backfill to stay idempotent)."
  @spec has_poll?(integer()) :: boolean()
  def has_poll?(note_id) when is_integer(note_id),
    do: Repo.exists?(from p in Poll, where: p.note_id == ^note_id)

  @spec get_with_results(integer() | String.t(), integer() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def get_with_results(poll_id, viewer_id \\ nil) do
    case SukhiFedi.Coercion.parse_id(poll_id) do
      nil ->
        {:error, :not_found}

      pid ->
        # A poll inherits its owning note's visibility — reading a
        # followers-only / direct poll's options and tallies is the same
        # disclosure as reading the note.
        case Repo.get(Poll, pid) do
          nil ->
            {:error, :not_found}

          %Poll{} = poll ->
            poll = Repo.preload(poll, :note)

            if is_nil(poll.note) or SukhiFedi.Notes.visible_to?(poll.note, viewer_id),
              do: {:ok, results_for(poll, viewer_id)},
              else: {:error, :not_found}
        end
    end
  end

  defp results_for(%Poll{id: pid} = poll, viewer_id) do
    options =
      Repo.all(
        from o in PollOption,
          where: o.poll_id == ^pid,
          order_by: [asc: o.position]
      )

    voted_option_ids =
      if is_integer(viewer_id), do: voted_options(pid, viewer_id), else: []

    # A remote poll's authoritative tallies ride on the cached option/poll
    # counts (the origin owns the count of votes cast on every server); a
    # local poll counts its own `poll_votes` rows. A viewer's own choice is
    # still highlighted from our `poll_votes` either way.
    {tallies, voters_count} =
      if remote_poll?(poll) do
        # Surface votes cast here even before the origin's count reflects them.
        # Some servers (e.g. hackers.pub) never send an Update, so the cached
        # remote count would otherwise show our local voters as having vanished.
        # max/2 (not +) avoids double-counting once the origin does catch up.
        remote = Map.new(options, fn o -> {o.id, o.votes_count} end)
        local = tally_for_poll(pid)
        merged = Map.merge(remote, local, fn _id, r, l -> max(r, l) end)
        {merged, max(poll.voters_count || 0, local_voters_count(pid))}
      else
        {tally_for_poll(pid), local_voters_count(pid)}
      end

    %{
      poll: poll,
      options: options,
      tallies: tallies,
      voters_count: voters_count,
      voted_option_ids: voted_option_ids,
      voted?: voted_option_ids != []
    }
  end

  # The owning note carries a `domain` only when it came from another server.
  defp remote_poll?(%Poll{note: %{domain: domain}}), do: not is_nil(domain)
  defp remote_poll?(_), do: false

  defp local_voters_count(pid) do
    Repo.aggregate(
      from(v in PollVote, where: v.poll_id == ^pid, select: v.account_id),
      :count,
      :account_id,
      distinct: true
    )
  end

  @doc """
  Ingest the poll carried by an inbound AP `Question` into a `Poll` plus
  its `poll_options`, snapshotting the tallies the activity reports. A
  no-op when the object isn't a poll (no `oneOf`/`anyOf`). Call it only
  on a freshly inserted note — the options are written once, not merged.

  Single-choice polls travel as `oneOf`, multiple-choice as `anyOf`. Each
  entry is a Note whose `name` is the option label and whose
  `replies.totalItems` is that option's running count. `endTime` (or
  `closed`) is the deadline; `votersCount` the distinct voter total.
  """
  @spec ingest_remote_poll(integer(), map()) :: :ok
  def ingest_remote_poll(note_id, %{} = object) do
    {choices, multiple?} = poll_choices(object)

    if is_list(choices) and choices != [] do
      rows =
        choices
        |> Enum.with_index()
        |> Enum.map(fn {choice, idx} ->
          %{title: option_title(choice), position: idx, votes_count: option_count(choice)}
        end)

      total = Enum.reduce(rows, 0, fn r, acc -> acc + r.votes_count end)

      {:ok, %Poll{id: pid}} =
        %Poll{}
        |> Poll.changeset(%{
          note_id: note_id,
          multiple: multiple?,
          expires_at: parse_end_time(object["endTime"] || object["closed"]),
          voters_count: parse_count(object["votersCount"]) || total
        })
        |> Repo.insert()

      Repo.insert_all("poll_options", Enum.map(rows, &Map.put(&1, :poll_id, pid)))
      :ok
    else
      :ok
    end
  end

  def ingest_remote_poll(_note_id, _), do: :ok

  @doc """
  Refresh an existing remote poll's cached tallies from a newer archived
  `Question` snapshot — a poll gains an `Update` on every vote, so the
  latest one carries the real counts. Updates each option's `votes_count`
  (matched by position, the order both were ingested in) and the poll's
  `voters_count`, without touching the rows' identity. No-op when the note
  owns no poll or the object isn't a poll.
  """
  @spec refresh_remote_poll_counts(integer(), map()) :: :ok | :no_poll | :no_poll_object
  def refresh_remote_poll_counts(note_id, %{} = object) do
    {choices, _multiple?} = poll_choices(object)

    case Repo.get_by(Poll, note_id: note_id) do
      nil ->
        :no_poll

      %Poll{} = poll when is_list(choices) ->
        total =
          from(o in PollOption, where: o.poll_id == ^poll.id, order_by: [asc: o.position])
          |> Repo.all()
          |> Enum.zip(choices)
          |> Enum.reduce(0, fn {opt, choice}, acc ->
            count = option_count(choice)
            opt |> Ecto.Changeset.change(votes_count: count) |> Repo.update!()
            acc + count
          end)

        poll
        |> Poll.changeset(%{voters_count: parse_count(object["votersCount"]) || total})
        |> Repo.update!()

        :ok

      %Poll{} ->
        :no_poll_object
    end
  end

  def refresh_remote_poll_counts(_note_id, _), do: :no_poll_object

  # A Question's options ride in `oneOf` (single choice) or `anyOf` (multiple).
  defp poll_choices(%{"oneOf" => list}) when is_list(list), do: {list, false}
  defp poll_choices(%{"anyOf" => list}) when is_list(list), do: {list, true}
  defp poll_choices(_), do: {nil, false}

  defp option_title(%{"name" => name}) when is_binary(name), do: name
  defp option_title(%{"content" => content}) when is_binary(content), do: content
  defp option_title(_), do: ""

  defp option_count(%{"replies" => %{"totalItems" => n}}), do: parse_count(n) || 0
  defp option_count(_), do: 0

  defp parse_count(n) when is_integer(n) and n >= 0, do: n
  defp parse_count(_), do: nil

  defp parse_end_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_end_time(_), do: nil

  @spec vote(integer(), integer() | String.t(), [integer() | String.t()]) ::
          :ok | {:error, :not_found | :expired | :too_many_choices}
  def vote(account_id, poll_id, choices) when is_integer(account_id) do
    with pid when not is_nil(pid) <- SukhiFedi.Coercion.parse_id(poll_id),
         %Poll{} = poll <- Repo.get(Poll, pid),
         poll = Repo.preload(poll, :note),
         :ok <- check_poll_visible(poll, account_id),
         :ok <- check_not_expired(poll),
         option_ids when is_list(option_ids) <- normalize_choices(poll, choices) do
      # Single-choice polls replace the prior ballot (Mastodon UX) instead
      # of accumulating — otherwise N requests with different choices stuff
      # N votes from one account.
      base =
        if poll.multiple do
          Multi.new()
        else
          Multi.delete_all(
            Multi.new(),
            :clear,
            from(v in PollVote, where: v.poll_id == ^pid and v.account_id == ^account_id)
          )
        end

      multi =
        Enum.reduce(option_ids, base, fn opt_id, acc ->
          Multi.insert(
            acc,
            {:vote, opt_id},
            PollVote.changeset(%PollVote{}, %{
              account_id: account_id,
              poll_id: pid,
              option_id: opt_id
            }),
            on_conflict: :nothing,
            conflict_target: [:account_id, :poll_id, :option_id]
          )
        end)
        |> maybe_enqueue_ballots(poll, account_id, option_ids)

      case Repo.transaction(multi) do
        {:ok, _} ->
          SukhiFedi.Graph.Local.changed({:votes, pid, account_id})
          :ok

        # Re-votes land in `on_conflict: :nothing` and still commit, so
        # an error here is a real failure — the poll/option vanished
        # under us. Don't report a vote that wasn't recorded.
        {:error, _op, _value, _changes} ->
          {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
      :hidden -> {:error, :not_found}
      :expired -> {:error, :expired}
      :too_many -> {:error, :too_many_choices}
      _ -> {:error, :not_found}
    end
  end

  # When the poll lives on another server, a local vote means nothing until the
  # origin hears it — so federate one Create(Note) ballot per chosen option (the
  # Mastodon vote shape: `name` = option, `inReplyTo` = the Question). For a
  # local poll the author is us and the rows already count, so nothing to send.
  # Enqueued in the same transaction as the vote, so the vote and its outbound
  # event commit together (no recorded-but-never-sent gap).
  defp maybe_enqueue_ballots(multi, %Poll{} = poll, account_id, option_ids) do
    if remote_poll?(poll) and is_binary(poll.note.ap_id) do
      titles = option_titles(option_ids)
      question_ap_id = poll.note.ap_id

      Enum.reduce(option_ids, multi, fn opt_id, acc ->
        Outbox.enqueue_multi(
          acc,
          {:vote_event, opt_id},
          "sns.outbox.vote.created",
          "vote",
          fn _ -> "#{poll.id}:#{opt_id}:#{account_id}" end,
          fn _ ->
            %{
              account_id: account_id,
              question_ap_id: question_ap_id,
              name: Map.get(titles, opt_id, ""),
              poll_id: poll.id,
              option_id: opt_id
            }
          end
        )
      end)
    else
      multi
    end
  end

  defp option_titles(option_ids) do
    Repo.all(from o in PollOption, where: o.id in ^option_ids, select: {o.id, o.title})
    |> Map.new()
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # A voter must be allowed to see the poll's owning note (same gate as
  # reading it), so a followers-only / direct poll can't be voted on by a
  # non-recipient who guessed the id.
  defp check_poll_visible(%Poll{} = poll, account_id) do
    note = Repo.preload(poll, :note).note

    if is_nil(note) or SukhiFedi.Notes.visible_to?(note, account_id),
      do: :ok,
      else: :hidden
  end

  defp tally_for_poll(poll_id) do
    Repo.all(
      from v in PollVote,
        where: v.poll_id == ^poll_id,
        group_by: v.option_id,
        select: {v.option_id, count(v.id)}
    )
    |> Map.new()
  end

  defp voted_options(poll_id, account_id) do
    Repo.all(
      from v in PollVote,
        where: v.poll_id == ^poll_id and v.account_id == ^account_id,
        select: v.option_id
    )
  end

  defp check_not_expired(%Poll{expires_at: nil}), do: :ok

  defp check_not_expired(%Poll{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :gt, do: :ok, else: :expired
  end

  defp normalize_choices(%Poll{multiple: multiple, id: pid}, choices) do
    ids = choices |> List.wrap() |> Enum.map(&SukhiFedi.Coercion.parse_id/1) |> Enum.reject(&is_nil/1)

    cond do
      ids == [] -> []
      not multiple and length(ids) > 1 -> :too_many
      true -> filter_owned_options(pid, ids)
    end
  end

  # Treat indices (0..N-1) the way Mastodon clients send them, but
  # accept absolute PollOption ids for clients that already resolved
  # the row. Indices look up by ordered position; ids look up by PK.
  defp filter_owned_options(poll_id, ids) do
    options =
      Repo.all(
        from o in PollOption,
          where: o.poll_id == ^poll_id,
          order_by: [asc: o.position],
          select: %{id: o.id, position: o.position}
      )

    by_id = Map.new(options, fn %{id: id} = o -> {id, o} end)
    by_position = Map.new(options, fn %{position: pos} = o -> {pos, o} end)

    ids
    |> Enum.map(fn id ->
      case Map.get(by_id, id) || Map.get(by_position, id) do
        nil -> nil
        %{id: oid} -> oid
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end

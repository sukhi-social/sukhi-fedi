# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Markers do
  @moduledoc """
  Where each person has read up to, for `home` and `notifications` (Mastodon's `/api/v1/markers`).
  It lives in PostgreSQL, not in hosigraph: it is written every time someone scrolls, read about as
  often, and it is only ever the latest value (nothing to keep, nothing to ask the past about).
  Reading ＞ writing ＞ erasing does not hold.

  `last_read_id` is a string the client gave and gets back: this module does not look inside it,
  so it does not care which id space the API shows. `account_id` is a hosigraph id with no foreign
  key (it is another store), so the rows go with the account by `erase/2`, which is for the caller
  of `Accounts.erase` to run after it (both can be run again).

  `upsert` is one statement: the version is raised by the database, so two writes at once are two
  versions, where a read followed by a write would lose one.
  """

  alias SukhiHosi.Notifications

  @allowed ~w(home notifications)

  def allowed?(t), do: t in @allowed

  @doc "The markers `account` has, for the `timelines` asked (only the two that exist)."
  def get(pg, account, timelines) do
    case Enum.filter(timelines, &allowed?/1) do
      [] ->
        %{}

      ts ->
        %{rows: rows} =
          Postgrex.query!(
            pg,
            "SELECT timeline, last_read_id, version FROM markers WHERE account_id = $1 AND timeline = ANY($2)",
            [account, ts]
          )

        Map.new(rows, fn [t, last, v] -> {t, %{last_read_id: last, version: v}} end)
    end
  end

  def upsert(pg, account, timeline, last_read_id) when is_binary(last_read_id) do
    if allowed?(timeline) do
      %{rows: [[v]]} =
        Postgrex.query!(
          pg,
          """
          INSERT INTO markers (account_id, timeline, last_read_id) VALUES ($1, $2, $3)
          ON CONFLICT (account_id, timeline)
          DO UPDATE SET last_read_id = EXCLUDED.last_read_id, version = markers.version + 1, updated_at = now()
          RETURNING version
          """,
          [account, timeline, last_read_id]
        )

      {:ok, %{timeline: timeline, last_read_id: last_read_id, version: v}}
    else
      {:error, :invalid_timeline}
    end
  end

  @doc """
  Mark as read, forward only: the place moves to `last_read_id` if that is later than where it is
  (ids that are digits are compared as numbers; one that is not is taken as it is). A second device
  that is behind cannot un-read what the first has read. `moved: false` says it did not move.
  """
  def advance(pg, account, timeline, last_read_id) when is_binary(last_read_id) do
    if allowed?(timeline) do
      %{rows: rows} =
        Postgrex.query!(
          pg,
          """
          INSERT INTO markers (account_id, timeline, last_read_id) VALUES ($1, $2, $3)
          ON CONFLICT (account_id, timeline)
          DO UPDATE SET last_read_id = EXCLUDED.last_read_id, version = markers.version + 1, updated_at = now()
          WHERE CASE WHEN markers.last_read_id ~ '^[0-9]+$' AND EXCLUDED.last_read_id ~ '^[0-9]+$'
                     THEN markers.last_read_id::numeric < EXCLUDED.last_read_id::numeric ELSE true END
          RETURNING version
          """,
          [account, timeline, last_read_id]
        )

      case rows do
        [[v]] -> {:ok, %{timeline: timeline, last_read_id: last_read_id, version: v, moved: true}}
        [] -> {:ok, Map.put(get(pg, account, [timeline])[timeline], :moved, false) |> Map.put(:timeline, timeline)}
      end
    else
      {:error, :invalid_timeline}
    end
  end

  @doc "Mark all of `account`'s notifications as read: up to the newest one there is. `:nothing` when there is none."
  def read_notifications(pg, db, account) do
    case Notifications.list(db, account, limit: 1) do
      [] -> :nothing
      [%{id: id}] -> advance(pg, account, "notifications", to_string(id))
    end
  end

  @doc "Take all of `account`'s markers away. How many went."
  def erase(pg, account) do
    %{num_rows: n} = Postgrex.query!(pg, "DELETE FROM markers WHERE account_id = $1", [account])
    n
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.ScheduledStatuses do
  @moduledoc """
  Statuses queued to publish at a future instant
  (`/api/v1/scheduled_statuses`).

  This module owns the *envelope*: it keeps the author's Mastodon-shaped
  create params verbatim and an Oban job scheduled for `publish_at`. It
  deliberately does not re-implement note creation — the
  `PublishWorker` replays the params through `Notes.create_status/2` at
  publish time, so the proven `Ecto.Multi` + transactional outbox path
  (validation, federation, zero-loss delivery) is reused, not copied.

  Ownership is the one security property here: every read and write is
  scoped by `account_id`, so an author only ever sees or touches their
  own schedules.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.ScheduledStatuses.PublishWorker
  alias SukhiFedi.Schema.{Account, ScheduledStatus}

  # The Oban instance is named (not the default `Oban`), same as every
  # other enqueue/cancel in this app.
  @oban SukhiFedi.Oban

  # Mastodon requires a scheduled time at least 5 minutes in the future;
  # a sooner `scheduled_at` is rejected (clients fall back to posting now).
  @min_lead_seconds 5 * 60

  @doc """
  Persist a status to publish at `scheduled_at` and schedule the Oban job
  that will publish it. `params` are the same Mastodon-shaped create
  attrs `create_status/2` accepts; they are stored verbatim and validated
  only at publish time (the same gate a live POST takes).

  Returns `{:ok, scheduled}`, `{:error, :too_soon}` when `scheduled_at`
  is not far enough ahead, or `{:error, :invalid_time}` when it can't be
  parsed.
  """
  @spec create(Account.t() | integer(), map(), DateTime.t() | String.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, :too_soon | :invalid_time | term()}
  def create(%Account{id: aid}, params, scheduled_at), do: create(aid, params, scheduled_at)

  def create(account_id, params, scheduled_at) when is_integer(account_id) do
    with {:ok, at} <- parse_time(scheduled_at),
         :ok <- far_enough_ahead(at),
         {:ok, scheduled} <-
           %ScheduledStatus{}
           |> ScheduledStatus.changeset(%{
             account_id: account_id,
             params: stringify(params),
             scheduled_at: at
           })
           |> Repo.insert(),
         {:ok, job} <- enqueue(scheduled, at) do
      scheduled |> Ecto.Changeset.change(oban_job_id: job.id) |> Repo.update()
    end
  end

  @doc "Every pending schedule the account owns, soonest first."
  @spec list(Account.t() | integer()) :: [ScheduledStatus.t()]
  def list(%Account{id: aid}), do: list(aid)

  def list(account_id) when is_integer(account_id) do
    from(s in ScheduledStatus,
      where: s.account_id == ^account_id,
      order_by: [asc: s.scheduled_at]
    )
    |> Repo.all()
  end

  @doc "One schedule the account owns, or `{:error, :not_found}`."
  @spec get(Account.t() | integer(), integer() | String.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, :not_found}
  def get(%Account{id: aid}, id), do: get(aid, id)

  def get(account_id, id) when is_integer(account_id) do
    case owned(account_id, id) do
      nil -> {:error, :not_found}
      scheduled -> {:ok, scheduled}
    end
  end

  @doc """
  Move a schedule's publish time. Reschedules the Oban job to match (we
  cancel the old job and insert a fresh one, since Oban jobs aren't
  re-timed in place). Same future-time rules as `create/3`.
  """
  @spec reschedule(Account.t() | integer(), integer() | String.t(), DateTime.t() | String.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, :not_found | :too_soon | :invalid_time | term()}
  def reschedule(%Account{id: aid}, id, scheduled_at), do: reschedule(aid, id, scheduled_at)

  def reschedule(account_id, id, scheduled_at) when is_integer(account_id) do
    with %ScheduledStatus{} = scheduled <- owned(account_id, id),
         {:ok, at} <- parse_time(scheduled_at),
         :ok <- far_enough_ahead(at),
         {:ok, job} <-
           Oban.insert(
             @oban,
             PublishWorker.new(%{scheduled_status_id: scheduled.id}, scheduled_at: at)
           ) do
      # New job is in before the old one goes, so a failed insert leaves
      # the schedule with a live job instead of none.
      cancel_job(scheduled.oban_job_id)

      scheduled
      |> Ecto.Changeset.change(scheduled_at: at, oban_job_id: job.id)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Cancel a schedule: delete its row and the Oban job that would have
  published it. Idempotent — a missing row is `{:error, :not_found}`.
  """
  @spec cancel(Account.t() | integer(), integer() | String.t()) ::
          {:ok, ScheduledStatus.t()} | {:error, :not_found}
  def cancel(%Account{id: aid}, id), do: cancel(aid, id)

  def cancel(account_id, id) when is_integer(account_id) do
    case owned(account_id, id) do
      nil ->
        {:error, :not_found}

      %ScheduledStatus{} = scheduled ->
        cancel_job(scheduled.oban_job_id)
        Repo.delete(scheduled)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # The single ownership gate: a schedule is only ever fetched scoped to
  # the asking account, so no read or write can touch another author's.
  defp owned(account_id, id) do
    case parse_int(id) do
      nil -> nil
      int -> Repo.get_by(ScheduledStatus, id: int, account_id: account_id)
    end
  end

  # The job lives in the queue store (`SukhiFedi.Queue.repo/0`), which is
  # not `Repo` under `SUKHI_STORE=datalevin`. Never thread this insert
  # through a `Repo.transaction` multi: Oban would write the job into the
  # multi's repo, where no queue ever looks, and the post would never go
  # out. So the row is written first and forgotten again if the job can't
  # be queued — a row without a job would sit "pending" forever.
  defp enqueue(%ScheduledStatus{id: id} = scheduled, at) do
    case Oban.insert(@oban, PublishWorker.new(%{scheduled_status_id: id}, scheduled_at: at)) do
      {:ok, _job} = ok ->
        ok

      {:error, _} = err ->
        Repo.delete(scheduled)
        err
    end
  end

  defp cancel_job(nil), do: :ok
  defp cancel_job(job_id) when is_integer(job_id), do: Oban.cancel_job(@oban, job_id)

  defp far_enough_ahead(%DateTime{} = at) do
    if DateTime.diff(at, DateTime.utc_now(), :second) >= @min_lead_seconds do
      :ok
    else
      {:error, :too_soon}
    end
  end

  defp parse_time(%DateTime{} = at), do: {:ok, DateTime.truncate(at, :second)}

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      {:error, _} -> {:error, :invalid_time}
    end
  end

  defp parse_time(_), do: {:error, :invalid_time}

  defp parse_int(id) when is_integer(id), do: id

  defp parse_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  # The params are stored as jsonb and round-trip back through
  # `create_status` (which reads both atom and string keys), so normalize
  # to string keys on the way in — a jsonb column would stringify them
  # anyway, and this keeps the stored shape obvious.
  defp stringify(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end
end

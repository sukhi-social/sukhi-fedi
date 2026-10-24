# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.Log do
  @moduledoc """
  The per-actor log a puller reads (`pull_log`), and the sequence numbers that
  order it (`pull_heads`). Written here, served by the gateway.

  A row is the signed activity body exactly as it would have been POSTed, so
  the puller's admission path sees the same bytes (and the same FEP-8b32
  proof) a push would have carried. `append/3` is idempotent on the activity
  id — an Oban retry of the fan-out appends once.
  """

  import Ecto.Query

  alias SukhiDelivery.Repo
  alias SukhiShared.PullStats

  # Per-actor cap, and the age past which rows go even under the cap. The
  # gateway answers a cursor older than the oldest kept row with a resync.
  @keep_per_actor 10_000
  @keep_days 14

  def keep_per_actor, do: @keep_per_actor
  def keep_days, do: @keep_days

  @doc """
  Append `body` to `account_id`'s log. Returns `{:ok, %{id, seq}}`; the
  existing row's numbers when `activity_id` is already there.
  """
  @spec append(integer(), String.t(), map()) :: {:ok, %{id: integer(), seq: integer()}}
  def append(account_id, activity_id, body)
      when is_integer(account_id) and is_binary(activity_id) do
    Repo.transaction(fn ->
      case existing(activity_id) do
        %{} = row ->
          row

        nil ->
          %{rows: [[seq]]} =
            Repo.query!(
              """
              INSERT INTO pull_heads (account_id, seq) VALUES ($1, 1)
              ON CONFLICT (account_id) DO UPDATE SET seq = pull_heads.seq + 1
              RETURNING seq
              """,
              [account_id]
            )

          %{rows: [[id]]} =
            Repo.query!(
              "INSERT INTO pull_log (account_id, seq, activity_id, body) VALUES ($1, $2, $3, $4) RETURNING id",
              [account_id, seq, activity_id, body]
            )

          PullStats.bump("log_appended")
          %{id: id, seq: seq}
      end
    end)
  end

  defp existing(activity_id) do
    Repo.one(
      from(l in "pull_log", where: l.activity_id == ^activity_id, select: %{id: l.id, seq: l.seq})
    )
  end

  @doc """
  Take an activity out of the log (a Delete is pushed to everyone, and a
  puller must not later be handed the Create it retracts). The sequence
  number stays used; pullers see a gap, which is harmless.
  """
  @spec retract(String.t()) :: non_neg_integer()
  def retract(activity_id) when is_binary(activity_id) do
    {n, _} = Repo.delete_all(from(l in "pull_log", where: l.activity_id == ^activity_id))
    n
  end

  @doc "Drop rows over the age or per-actor limits. Returns how many went."
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@keep_days * 86_400, :second)
    {aged, _} = Repo.delete_all(from(l in "pull_log", where: l.inserted_at < ^cutoff))

    %{num_rows: over} =
      Repo.query!(
        """
        DELETE FROM pull_log WHERE id IN (
          SELECT id FROM (
            SELECT id, row_number() OVER (PARTITION BY account_id ORDER BY seq DESC) AS rn FROM pull_log
          ) t WHERE rn > $1)
        """,
        [@keep_per_actor]
      )

    aged + over
  end
end

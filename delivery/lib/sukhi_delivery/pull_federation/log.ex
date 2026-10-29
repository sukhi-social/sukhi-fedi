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
          seq = next_seq(account_id)

          {1, [%{id: id}]} =
            Repo.insert_all(
              "pull_log",
              [%{account_id: account_id, seq: seq, activity_id: activity_id, body: body}],
              returning: [:id]
            )

          PullStats.bump("log_appended")
          %{id: id, seq: seq}
      end
    end)
  end

  # Create the head row if the actor has none, then count up. Plain statements
  # inside the caller's transaction (the update holds the row), so the same
  # code runs on every store.
  defp next_seq(account_id) do
    Repo.insert_all("pull_heads", [%{account_id: account_id, seq: 0}],
      on_conflict: :nothing,
      conflict_target: [:account_id]
    )

    from(h in "pull_heads", where: h.account_id == ^account_id, update: [inc: [seq: 1]])
    |> Repo.update_all([])

    Repo.one!(from(h in "pull_heads", where: h.account_id == ^account_id, select: h.seq))
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

  @doc """
  Drop rows past the age limit or over the per-actor cap, and remember per
  actor how far the pruning reached (`pull_heads.pruned_through`), so the
  gateway can tell a puller it has missed rows. Returns how many went.
  """
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@keep_days * 86_400, :second) |> DateTime.to_naive()

    Repo.transaction(fn ->
      aged = from(l in "pull_log", where: l.inserted_at < ^cutoff)
      over_cap = over_cap_seqs()

      reached =
        Map.merge(newest_per_actor(aged), over_cap, fn _, a, b -> max(a, b) end)

      {aged_n, _} = Repo.delete_all(aged)

      capped_n =
        Enum.reduce(over_cap, 0, fn {account_id, through}, n ->
          {k, _} =
            Repo.delete_all(
              from(l in "pull_log", where: l.account_id == ^account_id and l.seq <= ^through)
            )

          n + k
        end)

      for {account_id, through} <- reached do
        from(h in "pull_heads",
          where: h.account_id == ^account_id and h.pruned_through < ^through,
          update: [set: [pruned_through: ^through]]
        )
        |> Repo.update_all([])
      end

      aged_n + capped_n
    end)
    |> then(fn {:ok, n} -> n end)
  end

  defp newest_per_actor(query) do
    from(l in query, group_by: l.account_id, select: {l.account_id, max(l.seq)})
    |> Repo.all()
    |> Map.new()
  end

  # For each actor over the cap, the seq at or below which rows go: the
  # newest `@keep_per_actor` stay.
  defp over_cap_seqs do
    for {account_id, n} <-
          Repo.all(
            from(l in "pull_log",
              group_by: l.account_id,
              having: count(l.id) > ^@keep_per_actor,
              select: {l.account_id, count(l.id)}
            )
          ),
        into: %{} do
      {account_id, nth_oldest(account_id, n - @keep_per_actor)}
    end
  end

  defp nth_oldest(account_id, n) do
    Repo.one!(
      from(l in "pull_log",
        where: l.account_id == ^account_id,
        order_by: [asc: l.seq],
        offset: ^(n - 1),
        limit: 1,
        select: l.seq
      )
    )
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.AccountClosing do
  @moduledoc """
  The job that closes an account, one `step/4` at a time (sukhi's `AccountDeletion.finish_step`,
  which Oban's cron worker drives; this is its half that touches the data now in hosigraph).
  The booking, the day's grace, the mail and the blanking of the account's Postgres rows stay as
  they are in sukhi: this starts where the grace ends.

  In order, each step doing the first that applies:

    1. **Its posts go**, a batch at a time, the ops of each from `Notes.delete_ops` and the batch
       written with one `write_many`, so every one of them tells the relay (`Delete`).
    2. **The account itself is told**: one `DeleteActor` line, once (it goes to the followers and
       the relays, which is why the follows are still there).
    3. **Wait** until the relay has taken every line the account caused. Nothing is erased while a
       line is on its way: `Erase.account` takes the lines too, and a Delete that is erased before it
       is delivered is never sent.
    4. **Erase**, in both stores (`Erase.account`), and mark it finished.

  `step` returns `:more` (come again at once), `:waiting` (come again later; the relay has not
  caught up), `{:done, report}` (the step that erased), and `:done` (it was already finished).
  Every step looks at what is there now, and the two marks (`actor_deleted_at`, `finished_at`) are
  in Postgres, so a step that stops half way is made good by running it again.

  What "taken by the relay" means is `status = 'published'` of the `outbox` row. Whether that is
  after the fan-out has read the follows is the delivery side's, and is not looked at here.
  """

  alias SukhiHosi.{Actors, Erase, Notes, Store}

  @batch 50

  def step(db, pg, account, opts \\ []) do
    closing = closing(pg, account)

    cond do
      closing.finished_at -> :done
      (ids = notes(db, account, Keyword.get(opts, :batch, @batch))) != [] -> delete_all(db, ids, account)
      is_nil(closing.actor_deleted_at) -> tell_actor(db, pg, account)
      not delivered?(db, pg, account) -> :waiting
      true -> finish(db, pg, account)
    end
  end

  # One `write_many` for the batch: one fsync instead of one for each post. Each post is still its own
  # batch (atomic, with its own `Delete` line). `write_many` takes no `when`, so a post that someone
  # else's hand deleted between our look and our write is deleted again: nothing changes in the
  # facts, and the relay gets a second `Delete` line, which delivery's `(activity_id, inbox)` stops.
  defp delete_all(db, ids, account) do
    # a post that is already gone (or is not theirs) has no ops: someone else's hand got there first
    batches = for id <- ids, {:ok, ops} <- [Notes.delete_ops(db, id, account)], do: ops

    if batches != [] do
      {:ok, results} = Hosi.write_many(db, batches)
      for r <- results, not match?([:ok, _], r), do: raise("a delete was refused: #{inspect(r)}")
    end

    :more
  end

  defp tell_actor(db, pg, account) do
    sent = db |> Store.rows(~s([:find ?e :in $ ?a :where [?e :outbox/kind "DeleteActor"] [?e :outbox/actor ?a]]), [[:scalar, account]])

    if sent == [] do
      {:ok, _} =
        Hosi.write(db, [
          [:create, [:tmp, 1], :"outbox/kind", "DeleteActor"],
          [:create, [:tmp, 1], :"outbox/object", [:ref, account]],
          [:create, [:tmp, 1], :"outbox/actor", [:ref, account]],
          [:create, [:tmp, 1], :"outbox/ap-id", Actors.iri(db, account)]
        ])
    end

    Postgrex.query!(pg, "UPDATE account_closings SET actor_deleted_at = now() WHERE account_id = $1", [account])
    :more
  end

  # every line this account caused has been copied to Postgres and taken by the relay
  defp delivered?(db, pg, account) do
    ids = db |> Store.rows("[:find ?e :in $ ?a :where [?e :outbox/actor ?a]]", [[:scalar, account]]) |> List.flatten()

    %{rows: [[taken]]} =
      Postgrex.query!(pg, "SELECT count(*) FROM outbox WHERE source_id = ANY($1) AND status = 'published'", [ids])

    taken == length(ids)
  end

  defp finish(db, pg, account) do
    {:ok, report} = Erase.account(db, pg, account)
    Postgrex.query!(pg, "UPDATE account_closings SET finished_at = now() WHERE account_id = $1", [account])
    {:done, report}
  end

  defp notes(db, account, batch) do
    db
    |> Store.rows("[:find ?n :in $ ?a :where [?n :object/attributed-to ?a]]", [[:scalar, account]])
    |> List.flatten()
    |> Enum.sort()
    |> Enum.take(batch)
  end

  defp closing(pg, account) do
    Postgrex.query!(pg, "INSERT INTO account_closings (account_id) VALUES ($1) ON CONFLICT DO NOTHING", [account])

    %{rows: [[actor_deleted_at, finished_at]]} =
      Postgrex.query!(pg, "SELECT actor_deleted_at, finished_at FROM account_closings WHERE account_id = $1", [account])

    %{actor_deleted_at: actor_deleted_at, finished_at: finished_at}
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Erase do
  @moduledoc """
  Taking an account away from both places it lives in: hosigraph (its posts, follows,
  notifications, ...; `Accounts.erase`) and PostgreSQL (where it had read up to, and the outbox
  lines the feeder had already copied that it caused).

  The order is fixed: hosigraph first, then Postgres. Once hosigraph has let go, the feeder has
  nothing of the account left to copy, so the Postgres side only has to be cleaned once.
  (A feeder that was in the middle of a round while hosigraph erased can still commit a line
  afterward; calling `account/3` again takes it.)

  There is no transaction across the two. Instead each step looks at what is there now, so a stop
  half way is mended by calling again. What stays behind meanwhile is only ids in Postgres, never
  text.
  """

  alias SukhiHosi.{Accounts, Markers}

  @doc "Returns `{:ok, %{markers: n, outbox: n}}` (how many Postgres rows went), or hosigraph's error."
  def account(db, pg, account) do
    with {:ok, _} <- Accounts.erase(db, account) do
      {:ok, %{markers: Markers.erase(pg, account), outbox: erase_outbox(pg, account)}}
    end
  end

  # The lines this account caused: its posts, and what it did to others' (likes, boosts).
  defp erase_outbox(pg, account) do
    %{num_rows: n} =
      Postgrex.query!(pg, "DELETE FROM outbox WHERE (payload->>'account_id')::bigint = $1", [account])

    n
  end
end

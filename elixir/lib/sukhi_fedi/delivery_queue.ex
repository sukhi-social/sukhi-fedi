# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.DeliveryQueue do
  @moduledoc """
  Where the gateway enqueues `delivery`-queue sends (follow Accepts, quote
  and relay activities) and Web Push sends. They go into the gateway's own
  Oban: the jobs land in the one `oban_jobs` table of the queue database
  (`SukhiFedi.QueueRepo`), and the delivery node, which drains the `delivery`
  and `push` queues from that same table, picks them up. This node's Oban does
  not name those queues, so it never runs them.
  """

  @spec insert!(Ecto.Changeset.t()) :: Oban.Job.t()
  def insert!(changeset), do: Oban.insert!(SukhiFedi.Oban, changeset)

  @doc "Enqueue a Web Push send (the `push` queue is drained by the delivery node)."
  @spec insert_push(Ecto.Changeset.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert_push(changeset), do: Oban.insert(SukhiFedi.Oban, changeset)
end

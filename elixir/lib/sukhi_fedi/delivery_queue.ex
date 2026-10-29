# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.DeliveryQueue do
  @moduledoc """
  Where the gateway enqueues `delivery`-queue sends (follow Accepts, quote
  and relay activities). Normally its own Oban (Postgres). In a combined
  release started with `DELIVERY_QUEUE=sqlite`, the delivery app's runtime
  config points `:delivery_oban` at its SQLite-backed instance instead, so
  these sends land in the same queue the delivery node drains. A gateway on
  its own node never gets that setting and keeps using Postgres.
  """

  @spec insert!(Ecto.Changeset.t()) :: Oban.Job.t()
  def insert!(changeset) do
    Oban.insert!(Application.get_env(:sukhi_fedi, :delivery_oban, SukhiFedi.Oban), changeset)
  end

  @doc """
  Enqueue a Web Push send. The `push` queue is drained by the delivery node:
  with Postgres that is the gateway's own Oban (same database); with Datalevin
  the combined release points `:push_oban` at the delivery node's queue.
  """
  @spec insert_push(Ecto.Changeset.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert_push(changeset) do
    Oban.insert(Application.get_env(:sukhi_fedi, :push_oban, SukhiFedi.Oban), changeset)
  end
end

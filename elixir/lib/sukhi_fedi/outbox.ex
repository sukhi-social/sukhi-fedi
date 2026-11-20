# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Outbox do
  @moduledoc """
  Transactional Outbox writer.

  Use `enqueue_multi/6` inside an `Ecto.Multi` alongside the domain
  write so that the DB commit itself makes the event durable — the
  `SukhiDelivery.Outbox.Relay` process on the delivery node then
  turns pending rows into Oban delivery jobs.

  ## Example

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:note, Note.changeset(%Note{}, attrs))
      |> SukhiFedi.Outbox.enqueue_multi(
           :outbox_event,
           "sns.outbox.note.created",
           "note",
           & &1.note.id,
           fn %{note: note} ->
             %{note_id: note.id, account_id: note.account_id}
           end
         )
      |> SukhiFedi.Repo.transaction()
  """

  import Ecto.Query, only: [from: 2]

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.OutboxEvent
  alias Ecto.Multi

  @doc """
  The rows after `cursor` (an outbox id), oldest first, at most `limit` of
  them — for a reader that follows the outbox by id.
  """
  @spec after_id(integer(), pos_integer()) :: [OutboxEvent.t()]
  def after_id(cursor, limit) when is_integer(cursor) and is_integer(limit) do
    Repo.all(from(o in OutboxEvent, where: o.id > ^cursor, order_by: o.id, limit: ^limit))
  end

  @doc "The newest outbox id, or `0` when there is none."
  @spec last_id() :: non_neg_integer()
  def last_id do
    Repo.one(from(o in OutboxEvent, select: max(o.id))) || 0
  end

  @doc "How many rows are still `pending` (not yet handed to a dispatch job)."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    Repo.one(from(e in OutboxEvent, where: e.status == "pending", select: count(e.id))) || 0
  end

  @doc """
  Enqueue a single event outside any existing transaction.
  Prefer `enqueue_multi/6` when writing a domain entity in the same step.
  """
  def enqueue(subject, aggregate_type, aggregate_id, payload, headers \\ %{})
      when is_binary(subject) and is_binary(aggregate_type) and
             is_map(payload) and is_map(headers) do
    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      subject: subject,
      aggregate_type: aggregate_type,
      aggregate_id: to_string(aggregate_id),
      payload: payload,
      headers: headers
    })
    |> Repo.insert()
  end

  @doc """
  Append an outbox insert step to an existing `Ecto.Multi`.

  `aggregate_fn` and `payload_fn` each receive the accumulated changes
  map so they can pull values out of prior multi steps.
  """
  def enqueue_multi(multi, name, subject, aggregate_type, aggregate_fn, payload_fn)
      when is_binary(subject) and is_binary(aggregate_type) and
             is_function(aggregate_fn, 1) and is_function(payload_fn, 1) do
    Multi.insert(multi, name, fn changes ->
      OutboxEvent.changeset(%OutboxEvent{}, %{
        subject: subject,
        aggregate_type: aggregate_type,
        aggregate_id: to_string(aggregate_fn.(changes)),
        payload: payload_fn.(changes)
      })
    end)
  end
end

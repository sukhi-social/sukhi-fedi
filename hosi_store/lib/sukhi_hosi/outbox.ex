# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Outbox do
  @moduledoc """
  The relay's side. An id grows with the order things were written, so "after the id I last
  finished" is the whole cursor; it lives in one entity and moves only if nobody moved it first.

  Delivery is at-least-once: the cursor is moved after `deliver` has run. If the relay dies in
  between, the same lines come again, and the receiver knows them by `id`.
  """

  alias SukhiHosi.Store

  @doc "Lines with an id after `after_id`, oldest first."
  def after_id(db, after_id, limit \\ 100) do
    q = """
    [:find ?e ?kind ?note ?actor :in $ ?after
     :where [?e :outbox/kind ?kind] [(> ?e ?after)] [?e :outbox/object ?note] [?e :outbox/actor ?actor]]
    """

    lines = db |> Store.rows(q, [[:scalar, after_id]]) |> Enum.sort() |> Enum.take(limit)

    # a line about something that is gone (a Delete) carries the IRI it was known by
    for {[id, kind, note, actor], e} <- Enum.zip(lines, Store.entities(db, Enum.map(lines, &hd/1))) do
      %{id: id, kind: kind, note: note, actor: actor, ap_id: e |> Map.get(:"outbox/ap-id", []) |> List.first()}
    end
  end

  @doc "Where the relay called `name` has got to (it starts at 0)."
  def cursor(db, name) do
    {_entity, value} = ensure_cursor(db, name)
    value
  end

  @doc """
  One round: hand each new line to `deliver`, then move the cursor past them. Returns the lines
  delivered. If `deliver` raises, the cursor stays and the next round begins again at the same line.
  """
  def run_once(db, name, deliver, limit \\ 100) do
    {c, at} = ensure_cursor(db, name)

    case after_id(db, at, limit) do
      [] ->
        []

      lines ->
        Enum.each(lines, deliver)
        to = List.last(lines).id

        case Hosi.write(db, [[:create, c, :"relay/cursor", to]], when: [[:holds, c, :"relay/cursor", at]]) do
          {:ok, _} -> lines
          # another relay with this name moved it first: they own those lines now
          {:error, {:app, :conflict, _}} -> []
        end
    end
  end

  defp ensure_cursor(db, name) do
    case Store.lookup(db, :"relay/name", name) do
      nil ->
        # the name is an identity, so two creators cannot both succeed: the loser looks again
        _ = Hosi.write(db, [[:create, [:tmp, 1], :"relay/name", name], [:create, [:tmp, 1], :"relay/cursor", 0]])
        ensure_cursor(db, name)

      c ->
        {:ok, [e]} = Hosi.get_entities(db, [c])
        {c, e |> Map.fetch!(:"relay/cursor") |> hd()}
    end
  end
end

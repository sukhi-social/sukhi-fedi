# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.OutboxDoorsTest do
  @moduledoc """
  The doors `SukhiFedi.Outbox` opens for a reader of the outbox: the rows past
  a cursor, the newest id, how many are still pending.

      make test-pgrust ARGS="test/integration/outbox_doors_test.exs"
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag :integration

  alias SukhiFedi.Outbox
  alias SukhiFedi.Schema.OutboxEvent

  defp enqueue!(n) do
    {:ok, event} = Outbox.enqueue("sns.outbox.note.created", "note", n, %{"n" => n})
    event
  end

  test "an empty outbox has no newest id and nothing pending" do
    assert Outbox.last_id() == 0
    assert Outbox.pending_count() == 0
    assert Outbox.after_id(0, 10) == []
  end

  test "after_id/2 is the rows past the cursor, oldest first, at most the limit" do
    ids = for n <- 1..5, do: enqueue!(n).id

    assert Enum.map(Outbox.after_id(0, 10), & &1.id) == ids

    assert Enum.map(Outbox.after_id(Enum.at(ids, 1), 2), & &1.id) ==
             [Enum.at(ids, 2), Enum.at(ids, 3)]

    assert Outbox.after_id(List.last(ids), 10) == []
  end

  test "last_id/0 and pending_count/0 follow the rows" do
    [a, b, c] = for n <- 1..3, do: enqueue!(n)

    assert Outbox.last_id() == c.id
    assert Outbox.pending_count() == 3

    from(e in OutboxEvent, where: e.id in ^[a.id, b.id])
    |> SukhiFedi.AccountRepo.update_all(set: [status: "published"])

    assert Outbox.pending_count() == 1
    assert Outbox.last_id() == c.id
  end
end

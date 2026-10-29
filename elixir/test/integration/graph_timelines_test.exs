# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.GraphTimelinesTest do
  @moduledoc """
  With `SUKHI_GRAPH_READ`, the graph picks the page and the relational store
  supplies the notes: the answer is the same either way.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration
  @moduletag :dtlv

  alias SukhiFedi.Graph.{Local, Project}
  alias SukhiFedi.Timelines
  alias SukhiFedi.Schema.{Account, Note, Tag}

  setup do
    SukhiFedi.GraphCase.boot()
    Application.put_env(:sukhi_fedi, :graph, true)

    on_exit(fn ->
      Application.delete_env(:sukhi_fedi, :graph)
      Application.delete_env(:sukhi_fedi, :graph_read)
    end)

    alice = Repo.insert!(%Account{username: "alice_tl", display_name: "a", summary: ""})
    %{alice: alice}
  end

  defp post!(alice, text, visibility \\ "public", tag \\ nil) do
    note =
      Repo.insert!(%Note{account_id: alice.id, content: text, visibility: visibility, emojis: []})

    ap = Project.actor_iri(alice) <> "/notes/#{note.id}"
    note = note |> Ecto.Changeset.change(ap_id: ap) |> Repo.update!()

    if tag do
      t = Repo.get_by(Tag, name: tag) || Repo.insert!(%Tag{name: tag})
      Repo.insert_all("note_tags", [%{note_id: note.id, tag_id: t.id}])
    end

    :ok = Local.handle("sns.outbox.note.created", %{"note_id" => note.id}, DateTime.utc_now())
    # one millisecond apart, so the graph's order is the posting order
    Process.sleep(2)
    note
  end

  defp ids(notes), do: Enum.map(notes, & &1.id)

  test "public: same page as the relational query, and it pages by max_id", %{alice: alice} do
    notes = for i <- 1..5, do: post!(alice, "p#{i}")
    post!(alice, "secret", "direct")
    newest_first = notes |> Enum.reverse() |> ids()

    Application.put_env(:sukhi_fedi, :graph_read, true)

    page1 = Timelines.public(limit: 2, local: true)
    assert ids(page1) == Enum.take(newest_first, 2)

    page2 = Timelines.public(limit: 2, local: true, max_id: List.last(ids(page1)))
    assert ids(page2) == newest_first |> Enum.drop(2) |> Enum.take(2)

    # the last page is short in the graph's eyes too → the relational query answers
    page3 = Timelines.public(limit: 2, local: true, max_id: List.last(ids(page2)))
    assert ids(page3) == Enum.drop(newest_first, 4)

    Application.put_env(:sukhi_fedi, :graph_read, false)
    assert ids(Timelines.public(limit: 5, local: true)) == newest_first
  end

  test "a page the graph does not hold in full is answered by the relational store", %{
    alice: alice
  } do
    # written before the graph saw it: in Postgres only
    old =
      Repo.insert!(%Note{account_id: alice.id, content: "old", visibility: "public", emojis: []})

    old |> Ecto.Changeset.change(ap_id: "https://example.test/old/#{old.id}") |> Repo.update!()
    fresh = post!(alice, "fresh")

    Application.put_env(:sukhi_fedi, :graph_read, true)
    assert ids(Timelines.public(limit: 5, local: true)) == [fresh.id, old.id]
  end

  test "tag timeline", %{alice: alice} do
    a = post!(alice, "#neko", "public", "neko")
    _other = post!(alice, "inu", "public", "inu")
    b = post!(alice, "#neko 2", "public", "neko2")
    c = post!(alice, "#neko 3", "public", "neko")

    Application.put_env(:sukhi_fedi, :graph_read, true)
    assert ids(Timelines.tag("neko", limit: 2)) == [c.id, a.id]
    _ = b
  end
end

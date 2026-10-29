# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.GraphLocalTest do
  @moduledoc """
  What a local user does reaches the graph: outbox rows, and the hooks for what
  never federates. The relational rows are real; the graph is a throwaway `dtlv`.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration
  @moduletag :dtlv

  import Ecto.Query

  alias SukhiFedi.Graph
  alias SukhiFedi.Graph.{Local, Project}

  alias SukhiFedi.Schema.{
    Account,
    Bookmark,
    Follow,
    List,
    Media,
    Note,
    OutboxEvent,
    Poll,
    PollOption,
    PollVote
  }

  setup do
    SukhiFedi.GraphCase.boot()
    Process.delete({Local, :known, 1})
    :ok
  end

  defp account!(username, attrs \\ %{}) do
    Repo.insert!(struct(%Account{username: username, display_name: username, summary: ""}, attrs))
  end

  defp note!(account, attrs \\ %{}) do
    note =
      Repo.insert!(
        struct(
          %Note{account_id: account.id, content: "<p>ほんぶん</p>", visibility: "public", emojis: []},
          attrs
        )
      )

    ap = Project.actor_iri(account) <> "/notes/#{note.id}"
    note |> Ecto.Changeset.change(ap_id: ap) |> Repo.update!()
  end

  defp now, do: DateTime.utc_now()

  defp q(edn), do: Graph.query!(edn)

  test "a posted note arrives with its media, poll and both bodies" do
    alice = account!("alice_gl")
    note = note!(alice, %{mfm: "**ほんぶん**", cw: "ねたばれ", sensitive: true})

    media =
      Repo.insert!(%Media{
        url: "https://cdn/a.png",
        type: "image/png",
        description: "え",
        account_id: alice.id
      })

    Repo.insert_all("note_media", [%{note_id: note.id, media_id: media.id}])

    poll =
      Repo.insert!(%Poll{note_id: note.id, multiple: true, expires_at: ~U[2026-12-01 00:00:00Z]})

    Repo.insert!(%PollOption{poll_id: poll.id, title: "あ", position: 0})
    Repo.insert!(%PollOption{poll_id: poll.id, title: "い", position: 1})

    assert :ok = Local.handle("sns.outbox.note.created", %{"note_id" => note.id}, now())
    # a redelivered row is the same note
    assert :ok = Local.handle("sns.outbox.note.created", %{"note_id" => note.id}, now())

    assert [[":Question", "<p>ほんぶん</p>", "**ほんぶん**", ":public", "ねたばれ", true, true]] =
             q(
               "[:find ?t ?h ?m ?v ?s ?x ?l :where [?o :object/id \"#{note.ap_id}\"] [?o :object/type ?t] [?o :object/content-html ?h] [?o :object/content-mfm ?m] [?o :object/visibility ?v] [?o :object/summary ?s] [?o :object/sensitive? ?x] [?o :object/local? ?l]]"
             )

    assert [["https://cdn/a.png", "え"]] =
             q("[:find ?u ?a :where [?x :attachment/url ?u] [?x :attachment/alt ?a]]")

    assert [[true]] = q("[:find ?m :where [?p :poll/multiple? ?m]]")
    assert [["あ"], ["い"]] = Enum.sort(q("[:find ?t :where [?c :choice/title ?t]]"))

    assert [[true, "alice_gl"]] =
             q("[:find ?l ?u :where [?a :actor/local? ?l] [?a :actor/username ?u]]")
  end

  test "followers-only and direct notes keep their audience; a delete leaves a tombstone" do
    alice = account!("alice_vis")
    n1 = note!(alice, %{visibility: "followers"})
    n2 = note!(alice, %{visibility: "direct"})

    for n <- [n1, n2],
        do: assert(:ok = Local.handle("sns.outbox.note.created", %{"note_id" => n.id}, now()))

    assert [[":followers"], [":direct"]] =
             Enum.sort_by(q("[:find ?v :where [?o :object/visibility ?v]]"), &hd/1, :desc)

    assert :ok =
             Local.handle(
               "sns.outbox.note.deleted",
               %{"note_id" => n1.id, "ap_id" => n1.ap_id, "account_id" => alice.id},
               now()
             )

    assert [[":Tombstone"]] =
             q("[:find ?t :where [?o :object/id \"#{n1.ap_id}\"] [?o :object/type ?t]]")
  end

  test "like, reaction, boost and follow are edges; their undo removes them" do
    alice = account!("alice_edge")

    bob =
      account!("bob_edge", %{
        domain: "remote.example",
        actor_uri: "https://remote.example/users/bob"
      })

    note = note!(alice)
    assert :ok = Local.handle("sns.outbox.note.created", %{"note_id" => note.id}, now())

    like = %{
      "reaction_id" => 1,
      "account_id" => alice.id,
      "note_id" => note.id,
      "note_ap_id" => note.ap_id,
      "emoji" => "⭐"
    }

    react = %{like | "reaction_id" => 2, "emoji" => "🎉"}
    assert :ok = Local.handle("sns.outbox.like.created", like, now())
    assert :ok = Local.handle("sns.outbox.reaction.created", react, now())
    assert [["like"], ["u:🎉"]] = Enum.sort(q("[:find ?k :where [?r :reaction/key ?k]]"))

    assert :ok = Local.handle("sns.outbox.like.undone", like, now())
    assert [["u:🎉"]] = q("[:find ?k :where [?r :reaction/key ?k]]")

    boost = %{
      "boost_id" => 5,
      "account_id" => alice.id,
      "note_id" => note.id,
      "note_ap_id" => note.ap_id
    }

    assert :ok = Local.handle("sns.outbox.announce.created", boost, now())
    assert [[":Announce"]] = q("[:find ?t :where [?a :activity/type ?t] [(= ?t :Announce)]]")
    assert :ok = Local.handle("sns.outbox.announce.undone", boost, now())
    assert [] = q("[:find ?a :where [?a :activity/type :Announce]]")

    follow = %{
      "follow_id" => 9,
      "follower_uri" => Project.actor_iri(alice),
      "followee_id" => bob.id,
      "followee_username" => "bob_edge"
    }

    assert :ok = Local.handle("sns.outbox.follow.requested", follow, now())
    assert [[":pending"]] = q("[:find ?s :where [?f :follow/state ?s]]")
    assert :ok = Local.handle("sns.outbox.follow.undone", follow, now())
    assert [] = q("[:find ?f :where [?f :follow/state _]]")
  end

  test "pins, bookmarks and lists are set from their rows" do
    alice = account!("alice_state")
    bob = account!("bob_state")
    note = note!(alice)
    assert :ok = Local.handle("sns.outbox.note.created", %{"note_id" => note.id}, now())

    pin = %{
      "pinned_id" => 3,
      "account_id" => alice.id,
      "note_id" => note.id,
      "note_ap_id" => note.ap_id
    }

    assert :ok = Local.handle("sns.outbox.add.created", pin, now())
    assert [[3]] = q("[:find ?p :where [?e :pin/pos ?p]]")
    assert :ok = Local.handle("sns.outbox.remove.created", pin, now())
    assert [] = q("[:find ?p :where [?e :pin/pos ?p]]")

    Repo.insert!(%Bookmark{account_id: bob.id, note_id: note.id})
    assert :ok = Local.sync({:bookmark, bob.id, note.id})
    assert [[_]] = q("[:find ?b :where [?b :bookmark/at _]]")
    Repo.delete_all(Bookmark)
    assert :ok = Local.sync({:bookmark, bob.id, note.id})
    assert [] = q("[:find ?b :where [?b :bookmark/at _]]")

    list = Repo.insert!(%List{account_id: alice.id, title: "ともだち"})
    Repo.insert_all("list_accounts", [%{list_id: list.id, account_id: bob.id}])
    assert :ok = Local.sync({:list, list.id})

    assert [["ともだち", "bob_state"]] =
             q(
               "[:find ?t ?u :where [?l :list/title ?t] [?l :list/members ?m] [?m :actor/username ?u]]"
             )

    Repo.delete_all(from(la in "list_accounts", where: la.list_id == ^list.id))
    assert :ok = Local.sync({:list, list.id})
    assert [["ともだち"]] = q("[:find ?t :where [?l :list/title ?t]]")
    assert [] = q("[:find ?m :where [?l :list/members ?m]]")

    Repo.delete!(list)
    assert :ok = Local.sync({:list, list.id})
    assert [] = q("[:find ?t :where [?l :list/title ?t]]")
  end

  test "a vote on a local poll, and a follow between two local accounts" do
    alice = account!("alice_poll")
    bob = account!("bob_poll")
    note = note!(alice)
    poll = Repo.insert!(%Poll{note_id: note.id, multiple: false})
    a = Repo.insert!(%PollOption{poll_id: poll.id, title: "あ", position: 0})
    b = Repo.insert!(%PollOption{poll_id: poll.id, title: "い", position: 1})
    assert :ok = Local.handle("sns.outbox.note.created", %{"note_id" => note.id}, now())

    Repo.insert!(%PollVote{account_id: bob.id, poll_id: poll.id, option_id: a.id})
    assert :ok = Local.sync({:votes, poll.id, bob.id})
    assert [["あ"]] = q("[:find ?t :where [?v :vote/choice ?c] [?c :choice/title ?t]]")

    # a single-choice poll replaces the ballot
    Repo.delete_all(PollVote)
    Repo.insert!(%PollVote{account_id: bob.id, poll_id: poll.id, option_id: b.id})
    assert :ok = Local.sync({:votes, poll.id, bob.id})
    assert [["い"]] = q("[:find ?t :where [?v :vote/choice ?c] [?c :choice/title ?t]]")

    f =
      Repo.insert!(%Follow{
        follower_uri: Project.actor_iri(bob),
        followee_id: alice.id,
        state: "accepted"
      })

    assert :ok = Local.sync({:follow, f.id, f.follower_uri})
    assert [[":accepted"]] = q("[:find ?s :where [?f :follow/state ?s]]")
    Repo.delete!(f)
    assert :ok = Local.sync({:follow, f.id, f.follower_uri})
    assert [] = q("[:find ?f :where [?f :follow/state _]]")
  end

  test "the poller starts at the tail, handles new rows once, and remembers where it was" do
    alice = account!("alice_tail")
    old = note!(alice)

    Repo.insert!(%OutboxEvent{
      aggregate_type: "note",
      aggregate_id: "#{old.id}",
      subject: "sns.outbox.note.created",
      payload: %{"note_id" => old.id}
    })

    start_supervised!({Local, ticking: false})
    # history before the graph was on is not this process's job
    assert {:ok, 0} = Local.drain()
    assert [] = q("[:find ?o :where [?o :object/id _]]")

    fresh = note!(alice)

    for subject <- ["sns.outbox.note.created", "sns.outbox.dm.created"] do
      Repo.insert!(%OutboxEvent{
        aggregate_type: "note",
        aggregate_id: "#{fresh.id}",
        subject: subject,
        payload: %{"note_id" => fresh.id}
      })
    end

    assert {:ok, 2} = Local.drain()
    assert [[ap]] = q("[:find ?i :where [?o :object/id ?i]]")
    assert ap == fresh.ap_id
    assert {:ok, 0} = Local.drain()

    # after a restart it picks up from the stored cursor, not from the tail
    stop_supervised!(Local)
    later = note!(alice)

    Repo.insert!(%OutboxEvent{
      aggregate_type: "note",
      aggregate_id: "#{later.id}",
      subject: "sns.outbox.note.created",
      payload: %{"note_id" => later.id}
    })

    start_supervised!({Local, ticking: false})
    assert {:ok, 1} = Local.drain()
    assert 2 == length(q("[:find ?o :where [?o :object/id _]]"))
  end
end

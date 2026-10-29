# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.ProjectTest do
  use SukhiFedi.GraphCase, async: false

  alias SukhiFedi.Graph.{Activity, Project}
  alias SukhiFedi.Schema.{Account, Media, Note, Poll, PollOption}

  @bob "https://remote.example/users/bob"

  setup c do
    alice = %Account{id: 1, username: "alice", display_name: "Alice", domain: nil}
    me = Project.actor_iri(alice)
    %{alice: alice, me: me, opts: [raw_config: c.raw_config, local?: true]}
  end

  defp record(json, c) do
    raw = json |> :json.encode() |> IO.iodata_to_binary()
    Activity.record(json, [raw: raw, followers: Project.followers(c.alice)] ++ c.opts)
  end

  defp note(c, attrs \\ []) do
    struct!(
      %Note{
        id: 7,
        ap_id: c.me <> "/notes/7",
        account_id: 1,
        content: "<p>こんにちは</p>",
        visibility: "public",
        created_at: ~U[2026-10-29 01:00:00Z],
        emojis: []
      },
      attrs
    )
  end

  test "audience: each visibility says who it is for" do
    f = "https://x/f"

    assert {["https://www.w3.org/ns/activitystreams#Public"], [^f]} =
             Project.audience("public", f)

    assert {[^f], ["https://www.w3.org/ns/activitystreams#Public"]} =
             Project.audience("unlisted", f)

    assert {[^f], []} = Project.audience("followers", f)
    assert {[], []} = Project.audience("direct", f)
  end

  test "a local note keeps HTML and MFM, its attachments and emoji", c do
    media = [
      %Media{
        url: "https://cdn/x.png",
        type: "image/png",
        description: "ねこ",
        blurhash: "LEHV6n",
        width: 10,
        height: 20
      }
    ]

    emojis = [%{"shortcode" => "blob", "url" => "https://cdn/blob.png"}]
    n = note(c, mfm: "$[x2 こんにちは]", emojis: emojis)
    json = Project.note_activity("Create", n, c.alice, media, nil, ~U[2026-10-29 01:00:00Z])

    assert :ok = record(json, c)

    assert [[html, mfm, vis, true]] =
             Graph.query!(
               "[:find ?h ?m ?v ?l :where [?o :object/id \"#{n.ap_id}\"] [?o :object/content-html ?h] [?o :object/content-mfm ?m] [?o :object/visibility ?v] [?o :object/local? ?l]]"
             )

    assert html == "<p>こんにちは</p>"
    assert mfm == "$[x2 こんにちは]"
    assert vis == ":public"

    assert [["https://cdn/x.png", "image/png", "ねこ", "LEHV6n"]] =
             Graph.query!(
               "[:find ?u ?t ?a ?b :where [?o :object/id \"#{n.ap_id}\"] [?x :attachment/object ?o] [?x :attachment/url ?u] [?x :attachment/media-type ?t] [?x :attachment/alt ?a] [?x :attachment/blurhash ?b]]"
             )

    assert [["blob", "https://cdn/blob.png"]] =
             Graph.query!(
               "[:find ?n ?u :where [?o :object/id \"#{n.ap_id}\"] [?o :object/emojis ?e] [?e :emoji/name ?n] [?e :emoji/image-url ?u]]"
             )

    # the same note again (a redelivered outbox row) is still one of each
    assert :ok = record(json, c)
    assert [[1]] = Graph.query!("[:find (count ?x) :where [?x :attachment/url _]]")
  end

  test "a poll becomes choices, and a vote is an edge to a choice", c do
    poll = %Poll{
      multiple: false,
      expires_at: ~U[2026-11-01 00:00:00Z],
      options: [%PollOption{title: "はい", position: 0}, %PollOption{title: "いいえ", position: 1}]
    }

    n = note(c)

    assert :ok =
             record(Project.note_activity("Create", n, c.alice, [], poll, DateTime.utc_now()), c)

    assert [[":Question", false]] =
             Graph.query!(
               "[:find ?t ?m :where [?o :object/id \"#{n.ap_id}\"] [?o :object/type ?t] [?p :poll/object ?o] [?p :poll/multiple? ?m]]"
             )

    assert [["いいえ"], ["はい"]] =
             Enum.sort(
               Graph.query!(
                 "[:find ?t :where [?o :object/id \"#{n.ap_id}\"] [?p :poll/object ?o] [?c :choice/poll ?p] [?c :choice/title ?t] [?c :choice/pos ?i]]"
               )
             )

    vote = %{
      "id" => @bob <> "/votes/1",
      "type" => "Create",
      "actor" => @bob,
      "object" => %{
        "id" => @bob <> "/votes/1",
        "type" => "Note",
        "name" => "はい",
        "inReplyTo" => n.ap_id,
        "attributedTo" => @bob
      }
    }

    assert :ok = Activity.record(vote, [raw: "{}"] ++ c.opts)

    assert [["はい"]] =
             Graph.query!("[:find ?t :where [?v :vote/choice ?c] [?c :choice/title ?t]]")

    # a vote for a choice that is not there is ignored, not invented
    bad = put_in(vote, ["object", "name"], "たぶん")
    assert {:ignored, :unknown_poll} = Activity.record(bad, [raw: "{}"] ++ c.opts)
  end

  test "a custom emoji reaction carries its emoji; a plain favourite is a like", c do
    n = note(c)

    assert :ok =
             record(Project.note_activity("Create", n, c.alice, [], nil, DateTime.utc_now()), c)

    like = Project.reaction(%{id: 1}, c.alice, n.ap_id, "⭐", "2026-10-29T02:00:00Z")
    assert like["type"] == "Like"
    assert :ok = record(like, c)

    react = Project.reaction(%{id: 2}, c.alice, n.ap_id, ":blob:", "2026-10-29T02:01:00Z")
    assert react["type"] == "EmojiReact"
    assert :ok = record(react, c)

    assert [["e:urn:emoji:blob|:blob:"], ["like"]] =
             Enum.sort(Graph.query!("[:find ?k :where [?r :reaction/key ?k]]"))

    # undo takes the reaction away
    assert :ok = record(Project.undo(like["id"], c.me, "2026-10-29T02:05:00Z"), c)
    assert [["e:urn:emoji:blob|:blob:"]] = Graph.query!("[:find ?k :where [?r :reaction/key ?k]]")
  end

  test "edit and delete: an Update rewrites the body, a Delete leaves a tombstone", c do
    n = note(c)

    assert :ok =
             record(Project.note_activity("Create", n, c.alice, [], nil, DateTime.utc_now()), c)

    edited = %{n | content: "<p>なおした</p>"}

    assert :ok =
             record(
               Project.note_activity(
                 "Update",
                 edited,
                 c.alice,
                 [],
                 nil,
                 ~U[2026-10-29 03:00:00Z]
               ),
               c
             )

    assert [["<p>なおした</p>"]] = Graph.query!("[:find ?h :where [?o :object/content-html ?h]]")

    assert :ok = record(Project.delete(n.ap_id, c.alice), c)
    assert [[":Tombstone"]] = Graph.query!("[:find ?t :where [?o :object/type ?t]]")
    assert [] == Graph.query!("[:find ?h :where [?o :object/content-html ?h]]")
  end
end

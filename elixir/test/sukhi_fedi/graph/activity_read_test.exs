# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.ActivityReadTest do
  use SukhiFedi.GraphCase

  alias SukhiFedi.Graph.{Activity, Actor, Read, Tokens}
  alias SukhiFedi.Tokenizer.Sudachi

  @pub "https://www.w3.org/ns/activitystreams#Public"
  @me "https://l/u/me"
  @bob "https://r/u/bob"
  @cat "https://r/u/cat"

  setup c do
    {:ok, _} = Actor.upsert_local(%{iri: @me, username: "me", sid: 1})
    %{opts: [raw_config: c.raw_config, followers: nil]}
  end

  defp rec(a, c) do
    raw = :json.encode(a) |> IO.iodata_to_binary()
    Activity.record(a, Keyword.merge(c.opts, raw: raw))
  end

  defp create(id, actor, extra \\ %{}, t \\ "2023-01-01T00:00:00Z") do
    note =
      Map.merge(
        %{
          "id" => id,
          "type" => "Note",
          "attributedTo" => actor,
          "content" => "<p>#{id}</p>",
          "published" => t,
          "to" => [@pub],
          "cc" => []
        },
        extra
      )

    %{
      "id" => id <> "/act",
      "type" => "Create",
      "actor" => actor,
      "published" => t,
      "to" => [@pub],
      "object" => note
    }
  end

  test "follow: pending, accepted by Accept, gone by Undo or Reject", c do
    f = %{"id" => "https://l/f/1", "type" => "Follow", "actor" => @me, "object" => @bob}
    assert :ok = rec(f, c)
    assert [[":pending"]] = Graph.query!("[:find ?s :where [?f :follow/state ?s]]")

    assert :ok = rec(%{"type" => "Accept", "actor" => @bob, "object" => f}, c)
    assert [[":accepted"]] = Graph.query!("[:find ?s :where [?f :follow/state ?s]]")

    # the same pair again is the same edge
    assert :ok = rec(%{f | "id" => "https://l/f/1b"}, c)
    assert [[1]] = Graph.query!("[:find (count ?f) :where [?f :follow/pair _]]")

    assert :ok =
             rec(%{"type" => "Undo", "actor" => @me, "object" => %{"id" => "https://l/f/1b"}}, c)

    assert {:ignored, :unknown_activity} =
             rec(%{"type" => "Undo", "actor" => @me, "object" => "https://nope"}, c)
  end

  test "home: followees' posts and boosts, folded, newest first", c do
    f = %{"id" => "https://l/f/1", "type" => "Follow", "actor" => @me, "object" => @bob}
    :ok = rec(f, c)
    :ok = rec(%{"type" => "Accept", "actor" => @bob, "object" => f}, c)
    :ok = rec(%{"id" => "https://l/f/2", "type" => "Follow", "actor" => @me, "object" => @cat}, c)

    :ok =
      rec(
        %{
          "type" => "Accept",
          "actor" => @cat,
          "object" => %{"id" => "https://l/f/2", "actor" => @me}
        },
        c
      )

    :ok = rec(create("https://r/o/b1", @bob, %{}, "2023-01-01T00:00:01Z"), c)
    :ok = rec(create("https://r/o/stranger", "https://r/u/zed", %{}, "2023-01-01T00:00:02Z"), c)
    :ok = rec(create("https://r/o/mine", @me, %{}, "2023-01-01T00:00:03Z"), c)

    :ok =
      rec(
        %{
          "id" => "https://r/a/1",
          "type" => "Announce",
          "actor" => @cat,
          "object" => "https://r/o/b1",
          "published" => "2023-01-01T00:00:04Z"
        },
        c
      )

    :ok =
      rec(
        %{
          "id" => "https://r/a/2",
          "type" => "Announce",
          "actor" => @bob,
          "object" => "https://r/o/stranger",
          "published" => "2023-01-01T00:00:05Z"
        },
        c
      )

    home = Read.home(@me)

    assert ["https://r/o/stranger", "https://r/o/b1", "https://r/o/mine"] =
             Enum.map(home, & &1.id)

    assert [@bob] = Enum.find(home, &(&1.id == "https://r/o/stranger")).via
    assert [@cat] = Enum.find(home, &(&1.id == "https://r/o/b1")).via
    assert [] = Enum.find(home, &(&1.id == "https://r/o/mine")).via

    # paging by the cursor of the last row
    [first | _] = Read.home(@me, limit: 1)
    assert "https://r/o/stranger" == first.id

    assert ["https://r/o/b1", "https://r/o/mine"] =
             Read.home(@me, before: first.cursor) |> Enum.map(& &1.id)
  end

  test "public, author and thread timelines, paged by sid; direct never leaks", c do
    for i <- 1..5,
        do: :ok = rec(create("https://r/o/p#{i}", @bob, %{}, "2023-01-01T00:00:0#{i}Z"), c)

    :ok =
      rec(create("https://r/o/dm", @bob, %{"to" => [@me], "cc" => []}, "2023-01-01T00:00:09Z"), c)

    :ok =
      rec(
        create(
          "https://r/o/re",
          @cat,
          %{"inReplyTo" => "https://r/o/p1"},
          "2023-01-01T00:00:10Z"
        ),
        c
      )

    page1 = Read.public(limit: 3)
    assert ["https://r/o/re", "https://r/o/p5", "https://r/o/p4"] = Enum.map(page1, & &1.id)
    page2 = Read.public(limit: 3, before: List.last(page1).sid)
    assert ["https://r/o/p3", "https://r/o/p2", "https://r/o/p1"] = Enum.map(page2, & &1.id)

    refute "https://r/o/dm" in Enum.map(Read.author(@bob), & &1.id)
    assert "https://r/o/dm" in Enum.map(Read.author(@bob, visibilities: [:direct]), & &1.id)

    assert ["https://r/o/p1", "https://r/o/re"] = Enum.map(Read.thread("https://r/o/re"), & &1.id)
    assert "https://r/o/p1" == Enum.find(Read.public(), &(&1.id == "https://r/o/re")).reply_to
  end

  test "reactions notify the local author once, redelivery included", c do
    :ok = rec(create("https://l/o/mine", @me), c)

    like = %{
      "id" => "https://r/a/like",
      "type" => "Like",
      "actor" => @bob,
      "object" => "https://l/o/mine"
    }

    emoji = %{
      "id" => "https://r/a/emoji",
      "type" => "EmojiReact",
      "actor" => @cat,
      "object" => "https://l/o/mine",
      "content" => "❤️"
    }

    assert :ok = rec(like, c)
    assert :ok = rec(like, c)
    assert :ok = rec(emoji, c)

    assert ["like", "u:❤"] =
             Graph.query!("[:find ?k :where [?r :reaction/key ?k]]")
             |> List.flatten()
             |> Enum.sort()

    assert [%{type: "reaction", from: @cat}, %{type: "favourite", from: @bob}] =
             Read.notifications(@me)

    # a reaction to someone else's post notifies no one; Undo takes the notification with it
    assert :ok =
             rec(
               %{
                 "id" => "https://r/a/x",
                 "type" => "Like",
                 "actor" => @bob,
                 "object" => "https://r/o/other"
               },
               c
             )

    assert :ok = rec(%{"type" => "Undo", "actor" => @bob, "object" => like}, c)
    assert [%{type: "reaction"}] = Read.notifications(@me)
  end

  test "reply, mention and follow notify a local actor", c do
    :ok = rec(create("https://l/o/mine", @me), c)

    :ok =
      rec(
        create(
          "https://r/o/reply",
          @bob,
          %{"inReplyTo" => "https://l/o/mine"},
          "2023-01-01T00:00:02Z"
        ),
        c
      )

    :ok =
      rec(
        create(
          "https://r/o/ment",
          @cat,
          %{"tag" => [%{"type" => "Mention", "href" => @me}]},
          "2023-01-01T00:00:03Z"
        ),
        c
      )

    :ok =
      rec(
        %{
          "id" => "https://r/f/1",
          "type" => "Follow",
          "actor" => @bob,
          "object" => @me,
          "published" => "2023-01-01T00:00:04Z"
        },
        c
      )

    assert ["follow", "mention", "reply"] = Read.notifications(@me) |> Enum.map(& &1.type)
    assert [%{type: "follow"}] = Read.notifications(@me, limit: 1)
  end

  test "delete tombstones; the timeline stops showing it", c do
    :ok = rec(create("https://r/o/gone", @bob), c)
    assert [_] = Read.public()
    assert :ok = rec(%{"type" => "Delete", "actor" => @bob, "object" => "https://r/o/gone"}, c)
    assert [] = Read.public()
  end

  test "search finds segmented text; stranger visibility only", c do
    ja = fn tokens ->
      [
        engines: %{"ja" => Sudachi},
        engine_opts: [url: "http://s", request: fn _, _, _ -> {:ok, %{"tokens" => tokens}} end]
      ]
    end

    :ok =
      rec(
        create("https://r/o/ja", @bob, %{
          "content" => "<p>日本語の猫</p>",
          "contentMap" => %{"ja" => "日本語の猫"}
        }),
        c
      )

    :ok =
      rec(
        create("https://r/o/dm", @bob, %{
          "content" => "<p>日本語の猫</p>",
          "contentMap" => %{"ja" => "日本語の猫"},
          "to" => [@me],
          "cc" => []
        }),
        c
      )

    Tokens.run(tokenizer: ja.(["日本語", "の", "猫"]))

    q = Tokens.query_text("猫", "ja", ja.(["猫"]))
    assert ["https://r/o/ja"] = Read.search(q) |> Enum.map(& &1.id)
  end

  test "actors: remote from a document, local from the account", c do
    doc = %{
      "id" => @bob,
      "type" => "Person",
      "preferredUsername" => "bob",
      "inbox" => "https://r/u/bob/inbox",
      "endpoints" => %{"sharedInbox" => "https://r/inbox"},
      "publicKey" => %{"id" => @bob <> "#main-key", "publicKeyPem" => "PEM"}
    }

    assert {:ok, @bob} = Actor.ingest(doc, raw: "{}", raw_config: c.raw_config)

    assert {:ok, @bob} =
             Actor.ingest(%{doc | "type" => "Person"}, raw: "{}", raw_config: c.raw_config)

    assert {:error, :not_an_actor} = Actor.ingest(%{doc | "type" => "Note"}, raw: "{}")

    assert [["bob", "r", "https://r/inbox"]] =
             Graph.query!(
               "[:find ?u ?h ?s :where [?a :actor/id #{inspect(@bob)}] [?a :actor/username ?u] [?a :actor/host ?h] [?a :actor/shared-inbox ?s]]"
             )

    assert [[1]] = Graph.query!("[:find (count ?k) :where [?k :key/id _]]")

    assert [[true]] =
             Graph.query!(
               "[:find ?l :where [?a :actor/id #{inspect(@me)}] [?a :actor/local? ?l]]"
             )

    assert [[1]] = Graph.query!("[:find (count ?u) :where [?u :user/actor _]]")
  end

  test "the mirror copies a verified activity, skips a forged embedded object", c do
    ok = create("https://r/o/m1", @bob)
    forged = put_in(create("https://evil/o/m2", @bob), ["object", "attributedTo"], @bob)
    forged = %{forged | "actor" => @bob}

    assert :ok = SukhiFedi.Graph.Mirror.record(ok, c.opts)
    assert {:ignored, :cross_origin} = SukhiFedi.Graph.Mirror.record(forged, c.opts)
    assert ["https://r/o/m1"] = Read.public() |> Enum.map(& &1.id)
  end
end

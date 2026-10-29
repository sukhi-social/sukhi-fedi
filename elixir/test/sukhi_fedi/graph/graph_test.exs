# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.GraphTest do
  use SukhiFedi.GraphCase

  alias SukhiFedi.Graph.{Ingest, Sweep, Tokens}
  alias SukhiFedi.Tokenizer.Sudachi

  @pub "https://www.w3.org/ns/activitystreams#Public"
  @day 86_400 * 1_000_000

  defp note(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "type" => "Note",
        "attributedTo" => "https://r/u/a",
        "content" => "<p>hello</p>",
        "published" => "2023-01-01T00:00:00Z",
        "to" => [@pub],
        "cc" => ["https://r/u/a/followers"]
      },
      attrs
    )
  end

  defp ingest(json, c, opts \\ []) do
    raw = :json.encode(json) |> IO.iodata_to_binary()

    Ingest.object(
      json,
      Keyword.merge(
        [raw: raw, raw_config: c.raw_config, followers: "https://r/u/a/followers"],
        opts
      )
    )
  end

  defp one(edn), do: edn |> Graph.query!() |> List.flatten() |> List.first()
  defp ids(edn), do: edn |> Graph.query!() |> List.flatten() |> Enum.sort()

  test "ingest is an upsert and the sid is stable", c do
    assert {:ok, %{sid: sid, visibility: :public}} = ingest(note("https://r/o/1"), c)
    assert {:ok, %{sid: ^sid}} = ingest(note("https://r/o/1", %{"content" => "<p>edited</p>"}), c)
    assert ["https://r/o/1"] = ids("[:find ?i :where [?o :object/id ?i]]")
    assert "<p>edited</p>" = one("[:find ?c :where [?o :object/content-html ?c]]")
  end

  test "objects born in the same millisecond get different sids", c do
    {:ok, %{sid: a}} = ingest(note("https://r/o/1"), c)
    {:ok, %{sid: b}} = ingest(note("https://r/o/2"), c)
    assert a != b
  end

  test "visibility and the addressee entities", c do
    {:ok, %{visibility: :followers}} =
      ingest(note("https://r/o/f", %{"to" => ["https://r/u/a/followers"], "cc" => []}), c)

    {:ok, %{visibility: :direct}} =
      ingest(note("https://r/o/d", %{"to" => ["https://r/u/b"], "cc" => []}), c)

    {:ok, _} = ingest(note("https://r/o/p"), c)
    {:ok, _} = ingest(note("https://r/o/p2"), c)

    assert [":direct"] =
             ids("[:find ?v :where [?o :object/id \"https://r/o/d\"] [?o :object/visibility ?v]]")

    # as:Public is one collection entity, shared by every public object
    assert [1] = ids("[:find (count ?c) :where [?c :collection/id \"#{@pub}\"]]")

    assert [":followers"] =
             ids(
               "[:find ?k :where [?c :collection/id \"https://r/u/a/followers\"] [?c :collection/kind ?k]]"
             )

    assert ["https://r/u/b"] =
             ids(
               "[:find ?i :where [?o :object/id \"https://r/o/d\"] [?o :object/to ?a] [?a :actor/id ?i]]"
             )
  end

  test "html and Misskey source are kept apart; contentMap expands", c do
    {:ok, _} =
      ingest(
        note("https://r/o/m", %{
          "content" => "<p>$[x2 hi]</p>",
          "source" => %{"content" => "$[x2 hi]", "mediaType" => "text/x.misskeymarkdown"},
          "contentMap" => %{"ja" => "こんにちは", "en" => "hello"}
        }),
        c
      )

    {:ok, _} = ingest(note("https://r/o/plain"), c)
    assert "$[x2 hi]" = one("[:find ?m :where [?o :object/content-mfm ?m]]")
    assert 1 == length(Graph.query!("[:find ?o :where [?o :object/content-mfm _]]"))
    assert ["en", "ja"] = ids("[:find ?l :where [?b :content/lang ?l]]")
  end

  test "threads: root follows even when the parent arrives last", c do
    {:ok, _} = ingest(note("https://r/o/c", %{"inReplyTo" => "https://r/o/b"}), c)
    # before b arrives, b is taken as the root
    assert "https://r/o/b" =
             one(
               "[:find ?r :where [?o :object/id \"https://r/o/c\"] [?o :object/root ?x] [?x :object/id ?r]]"
             )

    {:ok, _} = ingest(note("https://r/o/b", %{"inReplyTo" => "https://r/o/a"}), c)
    {:ok, _} = ingest(note("https://r/o/a"), c)

    for id <- ~w(a b c) do
      assert "https://r/o/a" =
               one(
                 "[:find ?r :where [?o :object/id \"https://r/o/#{id}\"] [?o :object/root ?x] [?x :object/id ?r]]"
               )
    end
  end

  test "raw: small stays inline, large is a pointer that reads back", c do
    rc = %{c.raw_config | inline_max: 400}
    {:ok, _} = ingest(note("https://r/o/s", %{"content" => "x"}), c, raw_config: rc)

    {:ok, _} =
      ingest(note("https://r/o/l", %{"content" => String.duplicate("long ", 100)}), c,
        raw_config: rc
      )

    assert 1 == length(Graph.query!("[:find ?o :where [?o :object/raw _]]"))

    assert [[ref, size]] =
             Graph.query!("[:find ?r ?s :where [?o :object/raw-ref ?r] [?o :object/raw-size ?s]]")

    assert size > 400

    assert {:ok, raw} =
             SukhiFedi.RawStore.get(%{"object/raw-ref": ref}, "object", c.raw_config)

    assert raw =~ "long long"
  end

  test "tombstone keeps the identity and drops the body", c do
    {:ok, _} = ingest(note("https://r/o/t", %{"contentMap" => %{"ja" => "あ", "en" => "a"}}), c)
    assert {:ok, :deleted} = Ingest.tombstone("https://r/o/t")

    assert [":Tombstone"] =
             ids("[:find ?t :where [?o :object/id \"https://r/o/t\"] [?o :object/type ?t]]")

    assert [] = Graph.query!("[:find ?c :where [?o :object/content-html ?c]]")
    assert [] = Graph.query!("[:find ?c :where [?c :content/text _]]")
    assert [] = Graph.query!("[:find ?c :where [?c :object/raw _]]")
    assert {:ok, :unknown} = Ingest.tombstone("https://r/o/none")
  end

  describe "tokens (batch)" do
    @ja %{"content" => "<p>日本語の猫</p>", "contentMap" => %{"ja" => "日本語の猫"}}

    defp fake(tokens),
      do: [
        engines: %{"ja" => Sudachi},
        engine_opts: [url: "http://s", request: fn _, _, _ -> {:ok, %{"tokens" => tokens}} end]
      ]

    test "ingest leaves text unsearchable; the batch makes it searchable", c do
      {:ok, _} = ingest(note("https://r/o/j", @ja), c)
      search = "[:find ?i :where [(fulltext $ :object/tokens \"猫\") [[?o]]] [?o :object/id ?i]]"
      assert [] = Graph.query!(search)
      assert {1, 0} = Tokens.pending()

      assert %{done: 1, stopped: false} = Tokens.run(tokenizer: fake(["日本語", "の", "猫"]))
      assert {0, 0} = Tokens.pending()
      assert [["https://r/o/j"]] = Graph.query!(search)
      assert "日本語 の 猫" = Tokens.query_text("日本語の猫", "ja", fake(["日本語", "の", "猫"]))
    end

    test "a down service stops the batch instead of spinning; reset rebuilds", c do
      {:ok, _} = ingest(note("https://r/o/j", @ja), c)

      down = [
        engines: %{"ja" => Sudachi},
        engine_opts: [url: "http://s", request: fn _, _, _ -> {:error, :econnrefused} end]
      ]

      assert %{done: 0, degraded: 1, stopped: true} = Tokens.run(tokenizer: down)
      assert {1, 0} = Tokens.pending()

      assert %{done: 1} = Tokens.run(tokenizer: fake(["a"]))
      assert {:ok, 1} = Tokens.reset()
      assert {1, 0} = Tokens.pending()
    end
  end

  describe "sweep" do
    setup c do
      now = Graph.now()
      old = now - 30 * @day
      at = fn id, extra -> ingest(note(id, extra), c, now: old) end

      {:ok, _} = at.("https://r/o/lone", %{"contentMap" => %{"ja" => "あ", "en" => "a"}})
      {:ok, _} = at.("https://r/o/liked", %{})
      {:ok, _} = at.("https://r/o/thread-root", %{})

      {:ok, _} =
        ingest(
          note("https://r/o/thread-reply", %{
            "inReplyTo" => "https://r/o/thread-root",
            "attributedTo" => "https://l/u/me"
          }),
          c,
          now: old,
          local?: true
        )

      {:ok, _} = at.("https://r/o/young", %{})
      {:ok, _} = ingest(note("https://r/o/fresh", %{}), c, now: now)
      {:ok, _} = at.("https://r/o/by-followed", %{"attributedTo" => "https://r/u/friend"})
      {:ok, _} = at.("https://r/o/by-followed-ancient", %{"attributedTo" => "https://r/u/friend"})

      {:ok, _} =
        Graph.transact([
          %{":actor/id" => "https://l/u/me", ":actor/local?" => true},
          %{":db/id" => -1, ":actor/id" => "https://r/u/friend"},
          %{
            ":follow/follower" => [":actor/id", "https://l/u/me"],
            ":follow/followee" => -1,
            ":follow/state" => ":accepted"
          },
          %{
            ":activity/id" => "https://l/a/like",
            ":activity/type" => ":Like",
            ":activity/actor" => [":actor/id", "https://l/u/me"],
            ":activity/object" => [":object/id", "https://r/o/liked"]
          },
          # a young reply in an otherwise old thread
          %{
            ":object/id" => "https://r/o/young-reply",
            ":object/local?" => false,
            ":object/received-at" => now,
            ":object/root" => [":object/id", "https://r/o/young"]
          },
          # the followed author's older post is outside even the long TTL
          %{
            ":object/id" => "https://r/o/by-followed-ancient",
            ":object/received-at" => now - 120 * @day
          }
        ])

      %{now: now}
    end

    test "dry run explains, execute removes only what is unkept", %{now: now} do
      dry = Sweep.run(:dry_run, now: now)
      assert %{mode: :dry_run, delete: 2} = dry
      assert dry.kept.local_touch == 1
      assert dry.kept.local_thread == 1
      assert dry.kept.followed == 1
      assert dry.kept.young_thread >= 1
      done = Sweep.run(:execute, now: now)
      assert %{deleted: 2, dependents: 2} = done

      remaining = ids("[:find ?i :where [?o :object/id ?i] [?o :object/local? false]]")
      refute "https://r/o/lone" in remaining
      refute "https://r/o/by-followed-ancient" in remaining

      for kept <- ~w(liked thread-root young fresh by-followed) do
        assert "https://r/o/#{kept}" in remaining
      end

      assert [] = Graph.query!("[:find ?c :where [?c :content/text _]]")
      assert %{delete: 0} = Sweep.run(:dry_run, now: now)
    end

    test "gc removes only blobs nothing points at", %{now: now, raw_config: rc, blobs: blobs} do
      live = Agent.get(blobs, &map_size/1)
      assert live >= 6

      # an unreferenced blob, old enough
      Agent.update(blobs, &Map.put(&1, SukhiFedi.RawStore.ref("orphan"), {"x", 0}))
      assert {:ok, 1} = Sweep.gc(rc)
      assert live == Agent.get(blobs, &map_size/1)

      # swept objects take their originals with them (at the next gc)
      %{deleted: 2} = Sweep.run(:execute, now: now)
      assert {:ok, 2} = Sweep.gc(rc)
      assert live - 2 == Agent.get(blobs, &map_size/1)
    end
  end
end

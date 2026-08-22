# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RelaysTest do
  @moduledoc """
  Relay subscriptions: the `Follow` we send to join, the `Undo` we send
  to leave, the `Accept`/`Reject` that settles a row, and the gate that
  decides whether a forwarded activity is even looked at.

  DB-only. `subscribe/2`'s happy path fetches the relay's actor over
  NATS, so it is exercised here through its guard and by planting rows
  the way a settled subscription leaves them. The one live fetch the
  ingest path can make is likewise pinned down by pre-mirroring the note
  it would fetch — `NoteFetcher.fetch_and_mirror/1` answers from the
  `notes` table on a hit.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.AP.Instructions
  alias SukhiFedi.AP.Instructions.{Follows, Relayed}
  alias SukhiFedi.Relays
  alias SukhiFedi.Schema.{Account, InstanceBlock, Note, Notification, Relay}

  @public "https://www.w3.org/ns/activitystreams#Public"
  @relay_actor "https://relay.example/actor"
  @relay_inbox "https://relay.example/inbox"

  describe "subscribe/2" do
    test "refuses a URL that is not a public https address, and writes nothing" do
      admin = local!("relay_admin")

      assert {:error, :unsafe_url} = Relays.subscribe("http://relay.example/actor", admin)
      assert Repo.aggregate(Relay, :count, :id) == 0
    end
  end

  describe "the relay's answer" do
    test "Accept opens the subscription; Reject closes it" do
      relay = pending_relay!()

      Follows.maybe_handle_relay_reply(%{"type" => "Accept", "actor" => @relay_actor})
      assert Repo.get!(Relay, relay.id).state == "accepted"

      Follows.maybe_handle_relay_reply(%{"type" => "Reject", "actor" => @relay_actor})
      assert Repo.get!(Relay, relay.id).state == "rejected"
    end

    test "an Accept from someone who is not a relay we asked settles nothing" do
      relay = pending_relay!()

      Follows.maybe_handle_relay_reply(%{
        "type" => "Accept",
        "actor" => "https://stranger.example/users/bob"
      })

      assert Repo.get!(Relay, relay.id).state == "pending"
    end
  end

  describe "the accepted set" do
    test "only accepted relays are delivered to, and only their host is trusted" do
      pending_relay!()
      accepted_relay!("https://open.example/actor", "https://open.example/inbox")

      assert Relays.get_active_inbox_urls() == ["https://open.example/inbox"]

      assert Relays.accepted_host?("open.example")
      refute Relays.accepted_host?("relay.example")
      refute Relays.accepted_host?("stranger.example")
      refute Relays.accepted_host?(nil)
      refute Relays.accepted_host?("")
    end
  end

  describe "unsubscribe/1" do
    test "sends the Undo that echoes our Follow, then drops the row" do
      relay = accepted_relay!()

      assert {:ok, _} = manual(fn -> Relays.unsubscribe(relay.id) end)

      assert [job] = delivered_jobs()
      assert job.args["inbox_url"] == @relay_inbox
      assert job.args["actor_uri"] == relay.follow_actor_uri

      undo = job.args["raw_json"]
      assert undo["type"] == "Undo"
      assert undo["actor"] == relay.follow_actor_uri
      assert undo["object"]["type"] == "Follow"
      assert undo["object"]["id"] == relay.follow_activity_id
      assert undo["object"]["actor"] == relay.follow_actor_uri
      assert undo["object"]["object"] == @public

      assert Repo.get(Relay, relay.id) == nil
    end

    test "a row from before we recorded the Follow leaves locally, quietly" do
      relay =
        Repo.insert!(%Relay{actor_uri: @relay_actor, inbox_uri: @relay_inbox, state: "accepted"})

      assert {:ok, _} = manual(fn -> Relays.unsubscribe(relay.id) end)

      assert delivered_jobs() == []
      assert Repo.get(Relay, relay.id) == nil
    end

    test "an unknown id is not found" do
      assert {:error, :not_found} = Relays.unsubscribe(999_999)
    end
  end

  describe "maybe_ingest/2 — what a relay is allowed to hand us" do
    setup do
      accepted_relay!()
      :ok
    end

    test "a public Create from an accepted relay mirrors the origin's note" do
      uri = remote_note!("https://origin.example/notes/1")

      assert :mirrored = Relayed.maybe_ingest(create(uri), "relay.example")
    end

    test "an Announce is read as 'go look at this note', not as a boost by the relay" do
      uri = remote_note!("https://origin.example/notes/2")

      assert :mirrored =
               Relayed.maybe_ingest(
                 %{
                   "type" => "Announce",
                   "actor" => @relay_actor,
                   "object" => uri,
                   "to" => [@public]
                 },
                 "relay.example"
               )
    end

    test "the same activity signed by anyone else is not relayed input" do
      uri = remote_note!("https://origin.example/notes/3")

      assert :not_relayed = Relayed.maybe_ingest(create(uri), "stranger.example")
      assert :not_relayed = Relayed.maybe_ingest(create(uri), nil)
    end

    test "a relay we have only asked (still pending) is not trusted yet" do
      Repo.delete_all(Relay)
      pending_relay!()
      uri = remote_note!("https://origin.example/notes/4")

      assert :not_relayed = Relayed.maybe_ingest(create(uri), "relay.example")
    end

    test "a non-public post stops at the audience" do
      uri = remote_note!("https://origin.example/notes/5")

      followers = %{
        "type" => "Create",
        "actor" => "https://origin.example/users/a",
        "object" => %{
          "type" => "Note",
          "id" => uri,
          "attributedTo" => "https://origin.example/users/a",
          "to" => ["https://origin.example/users/a/followers"]
        }
      }

      assert :not_public = Relayed.maybe_ingest(followers, "relay.example")
    end

    test "our own post bounced back by the relay is not mirrored again" do
      alice = local!("relay_boomerang")
      uri = "https://#{SukhiFedi.Config.domain!()}/users/#{alice.username}/notes/1"

      assert :own_host = Relayed.maybe_ingest(create(uri), "relay.example")
    end

    test "a suspended instance cannot walk in through the relay" do
      Repo.insert!(%InstanceBlock{domain: "blocked.example", severity: "suspend"})
      uri = remote_note!("https://blocked.example/notes/1")

      assert :blocked = Relayed.maybe_ingest(create(uri), "relay.example")
    end

    test "an Update or Delete forwarded by a relay is not acted on" do
      uri = remote_note!("https://origin.example/notes/6")

      for type <- ["Update", "Delete"] do
        assert :unhandled =
                 Relayed.maybe_ingest(
                   %{"type" => type, "actor" => "https://origin.example/users/a", "object" => uri},
                   "relay.example"
                 )
      end
    end
  end

  describe "maybe_ingest/3 — a body the author signed (FEP-8b32)" do
    setup do
      accepted_relay!()
      :ok
    end

    test "is mirrored from the body, with no round trip to the origin" do
      # The author exists as a shadow account, the note does not. Nothing
      # in this test env can reach the network (no NATS), so a row can
      # only appear if the signed body itself was believed.
      remote_author!("origin.example")
      uri = "https://origin.example/notes/signed-1"

      assert :mirrored_signed =
               Relayed.maybe_ingest(create(uri, "signed hello"), "relay.example", true)

      assert %Note{content: content} = Repo.get_by(Note, ap_id: uri)
      assert content =~ "signed hello"
    end

    test "without the proof the same activity reaches for the origin" do
      remote_author!("origin.example")
      uri = "https://origin.example/notes/signed-2"

      # The contrast that makes the test above mean something: unsigned,
      # the very same activity goes out to fetch the note. This env has
      # no NATS, so the fetch client exits — which is exactly the
      # observation we want (it tried), and the row never appears.
      assert catch_exit(Relayed.maybe_ingest(create(uri), "relay.example", false))
      assert Repo.get_by(Note, ap_id: uri) == nil
    end

    test "a proof does not let the body carry someone else's post" do
      # Signed by origin.example, but the note id and its author live on
      # another host. `Mirror` refuses; the proof vouches for the bytes,
      # never for the claim inside them.
      remote_author!("elsewhere.example")

      forged = %{
        "type" => "Create",
        "actor" => "https://origin.example/users/a",
        "object" => %{
          "type" => "Note",
          "id" => "https://elsewhere.example/notes/1",
          "attributedTo" => "https://elsewhere.example/users/a",
          "content" => "<p>not mine</p>",
          "to" => [@public]
        }
      }

      assert :unresolved = Relayed.maybe_ingest(forged, "relay.example", true)
      assert Repo.get_by(Note, ap_id: "https://elsewhere.example/notes/1") == nil
    end

    test "a proof buys nothing on an Announce — that path still fetches" do
      uri = remote_note!("https://origin.example/notes/announced")

      announce = %{
        "type" => "Announce",
        "actor" => @relay_actor,
        "object" => uri,
        "to" => [@public]
      }

      assert :mirrored = Relayed.maybe_ingest(announce, "relay.example", true)
    end

    test "a proof opens no gate that was closed: public, origin, own host" do
      remote_author!("origin.example")

      followers_only = %{
        "type" => "Create",
        "actor" => "https://origin.example/users/a",
        "object" => %{
          "type" => "Note",
          "id" => "https://origin.example/notes/private-1",
          "attributedTo" => "https://origin.example/users/a",
          "to" => ["https://origin.example/users/a/followers"]
        }
      }

      assert :not_public = Relayed.maybe_ingest(followers_only, "relay.example", true)

      Repo.insert!(%InstanceBlock{domain: "blocked.example", severity: "suspend"})
      remote_author!("blocked.example")

      assert :blocked =
               Relayed.maybe_ingest(create("https://blocked.example/notes/1"), "relay.example", true)

      alice = local!("relay_signed_boomerang")
      own = "https://#{SukhiFedi.Config.domain!()}/users/#{alice.username}/notes/1"
      assert :own_host = Relayed.maybe_ingest(create(own), "relay.example", true)
    end

    test "a relayed post never raises a mention notification" do
      remote_author!("origin.example")
      mentioned = local!("relay_mentioned")
      uri = "https://origin.example/notes/signed-mention"

      assert :mirrored_signed =
               Relayed.maybe_ingest(create(uri, "hey @relay_mentioned"), "relay.example", true)

      assert %Note{} = Repo.get_by(Note, ap_id: uri)

      assert Repo.aggregate(from(n in Notification, where: n.account_id == ^mentioned.id), :count) ==
               0
    end
  end

  describe "the inbox dispatcher" do
    test "a relay's forward reaches the relay path, an ordinary forward does not" do
      accepted_relay!()
      uri = remote_note!("https://origin.example/notes/7")
      before = Repo.aggregate(Note, :count, :id)

      # `save` with a signer host that is not the actor's host is the
      # forwarded/relayed branch of `Instructions.execute/2`.
      save = %{"action" => "save", "object" => create(uri)}

      assert :ok = Instructions.execute(save, "relay.example")
      assert :ok = Instructions.execute(save, "stranger.example")

      # Neither minted anything — the note was already mirrored, and
      # neither path trusts the forwarded body enough to insert a row.
      assert Repo.aggregate(Note, :count, :id) == before

      # The FEP-8b32 verdict does reach `Relayed`, though: a signed body
      # mirrors a note nothing here ever fetched.
      remote_author!("proven.example")
      proven = "https://proven.example/notes/1"
      signed = %{"action" => "save", "object" => create(proven, "via the dispatcher")}

      assert :ok = Instructions.execute(signed, "relay.example", true)
      assert %Note{} = Repo.get_by(Note, ap_id: proven)
    end
  end

  describe "the relays admin template" do
    test "renders every state, and the empty list" do
      alias SukhiFedi.Web.Admin.Render

      row = fn state ->
        %Relay{
          id: 1,
          actor_uri: @relay_actor,
          inbox_uri: @relay_inbox,
          state: state,
          follow_actor_uri: "https://#{SukhiFedi.Config.domain!()}/users/admin",
          inserted_at: ~U[2026-08-21 00:00:00Z]
        }
      end

      for state <- ["pending", "accepted", "rejected"] do
        html = Render.render_template("relays/index.html.eex", relays: [row.(state)])
        assert html =~ state
        assert html =~ @relay_actor
      end

      empty = Render.render_template("relays/index.html.eex", relays: [])
      assert empty =~ "Not subscribed to any relay."
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp local!(username) do
    Repo.insert!(%Account{username: username, display_name: username, summary: ""})
  end

  defp pending_relay! do
    Repo.insert!(%Relay{
      actor_uri: @relay_actor,
      inbox_uri: @relay_inbox,
      state: "pending",
      follow_actor_uri: "https://#{SukhiFedi.Config.domain!()}/users/admin",
      follow_activity_id: "https://#{SukhiFedi.Config.domain!()}/activities/follow/abc"
    })
  end

  defp accepted_relay!(actor \\ @relay_actor, inbox \\ @relay_inbox) do
    Repo.insert!(%Relay{
      actor_uri: actor,
      inbox_uri: inbox,
      state: "accepted",
      follow_actor_uri: "https://#{SukhiFedi.Config.domain!()}/users/admin",
      follow_activity_id: "https://#{SukhiFedi.Config.domain!()}/activities/follow/abc"
    })
  end

  # A note already in the mirror: `fetch_and_mirror/1` returns it without
  # reaching for the network, so the ingest path is testable end to end.
  defp remote_note!(ap_id) do
    author =
      Repo.insert!(%Account{
        username: "rn_#{System.unique_integer([:positive])}",
        display_name: "rn",
        summary: "",
        domain: URI.parse(ap_id).host,
        actor_uri: "https://#{URI.parse(ap_id).host}/users/a"
      })

    Repo.insert!(%Note{
      account_id: author.id,
      content: "relayed",
      visibility: "public",
      ap_id: ap_id
    })

    ap_id
  end

  # The shadow Account a mirrored note hangs off. Without it `Mirror`
  # would ingest the actor over the network, which this env cannot do.
  defp remote_author!(host) do
    Repo.insert!(%Account{
      username: "ra_#{System.unique_integer([:positive])}",
      display_name: "ra",
      summary: "",
      domain: host,
      actor_uri: "https://#{host}/users/a"
    })
  end

  defp create(uri, body \\ "relayed") do
    host = URI.parse(uri).host

    %{
      "type" => "Create",
      "actor" => "https://#{host}/users/a",
      "object" => %{
        "type" => "Note",
        "id" => uri,
        "attributedTo" => "https://#{host}/users/a",
        "content" => "<p>#{body}</p>",
        "to" => [@public]
      }
    }
  end

  # Delivery runs on another BEAM node, so its Oban worker isn't loaded
  # here — enqueue in :manual mode and inspect the job instead of letting
  # :inline run a missing worker.
  defp manual(fun), do: Oban.Testing.with_testing_mode(:manual, fun)

  defp delivered_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "SukhiDelivery.Delivery.Worker"))
  end
end

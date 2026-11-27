# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SukhiFedi.Integration.NoteFederationTest do
  @moduledoc """
  Inbound federation scenarios applied by `SukhiFedi.AP.Instructions`.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Config, Conversations, Notes}
  alias SukhiFedi.AP.Instructions
  alias SukhiFedi.Schema.{Account, ConversationParticipant, Note, Notification, Reaction}

  describe "stage-0 smoke" do
    test "mock remote bypass is openable", %{mock_remote: bypass} do
      assert is_integer(bypass.port)
      assert bypass.port > 0
    end
  end

  describe "inbound reactions (Like / EmojiReact)" do
    test "EmojiReact materialises a reactions row + favourite notification" do
      author = create_account!("emoji_author")
      reactor = create_remote_account!("emoji_reactor", "remote.example")
      {:ok, note} = Notes.create_status(author, %{"status" => "react to me"})

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "EmojiReact",
                   "actor" => reactor.actor_uri,
                   "object" => local_note_uri(author, note),
                   "content" => "🦊"
                 }
               })

      assert Repo.get_by(Reaction, account_id: reactor.id, note_id: note.id, emoji: "🦊")

      assert Repo.get_by(Notification,
               account_id: author.id,
               from_account_id: reactor.id,
               note_id: note.id,
               type: "favourite"
             )
    end

    test "Like materialises a star reaction" do
      author = create_account!("like_author")
      reactor = create_remote_account!("like_reactor", "remote.example")
      {:ok, note} = Notes.create_status(author, %{"status" => "like me"})

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Like",
                   "actor" => reactor.actor_uri,
                   "object" => local_note_uri(author, note)
                 }
               })

      assert Repo.get_by(Reaction, account_id: reactor.id, note_id: note.id, emoji: "⭐")
    end

    test "Undo(EmojiReact) removes the reaction row" do
      author = create_account!("undo_author")
      reactor = create_remote_account!("undo_reactor", "remote.example")
      {:ok, note} = Notes.create_status(author, %{"status" => "undo me"})

      react = %{
        "type" => "EmojiReact",
        "actor" => reactor.actor_uri,
        "object" => local_note_uri(author, note),
        "content" => "🦊"
      }

      :ok = Instructions.execute(%{"action" => "save", "object" => react})
      assert Repo.get_by(Reaction, account_id: reactor.id, note_id: note.id, emoji: "🦊")

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{"type" => "Undo", "actor" => reactor.actor_uri, "object" => react}
               })

      refute Repo.get_by(Reaction, account_id: reactor.id, note_id: note.id, emoji: "🦊")
    end
  end

  describe "inbound note publish time" do
    test "Create(Note) keeps the remote published date as created_at" do
      author = create_remote_account!("dated_author", "remote.example")
      note_uri = "https://remote.example/notes/dated1"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "an old post",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "published" => "2021-03-14T09:26:53Z"
                   }
                 }
               })

      note = Repo.get_by(Note, ap_id: note_uri)
      assert DateTime.compare(note.created_at, ~U[2021-03-14 09:26:53Z]) == :eq
    end

    test "Create(Note) without published falls back to insert time" do
      author = create_remote_account!("undated_author", "remote.example")
      note_uri = "https://remote.example/notes/undated1"
      before = DateTime.add(DateTime.utc_now(), -5, :second)

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "no date",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"]
                   }
                 }
               })

      note = Repo.get_by(Note, ap_id: note_uri)
      assert DateTime.compare(note.created_at, before) == :gt
    end
  end

  describe "inbound content warning" do
    test "Create(Note) with a summary stores it as the content warning" do
      author = create_remote_account!("cw_author", "remote.example")
      note_uri = "https://remote.example/notes/cw1"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "the spoilery body",
                     "summary" => "CW: late-game spoilers",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"]
                   }
                 }
               })

      assert %Note{cw: "CW: late-game spoilers"} = Repo.get_by(Note, ap_id: note_uri)
    end

    test "Create(Note) with no summary leaves cw nil" do
      author = create_remote_account!("nocw_author", "remote.example")
      note_uri = "https://remote.example/notes/nocw1"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "no warning here",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"]
                   }
                 }
               })

      assert %Note{cw: nil} = Repo.get_by(Note, ap_id: note_uri)
    end
  end

  describe "inbound custom emoji" do
    test "Create(Note) with Emoji tags stores them in note.emojis" do
      author = create_remote_account!("emoji_author", "remote.example")
      note_uri = "https://remote.example/notes/emoji1"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "hi :blobcat:",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "tag" => [
                       %{
                         "type" => "Emoji",
                         "name" => ":blobcat:",
                         "icon" => %{"url" => "https://remote.example/e/blobcat.png"}
                       }
                     ]
                   }
                 }
               })

      note = Repo.get_by(Note, ap_id: note_uri)

      assert [%{"shortcode" => "blobcat", "url" => "https://remote.example/e/blobcat.png"}] =
               note.emojis
    end

    test "upsert_from_actor_json captures name/bio emoji onto the account" do
      actor_uri = "https://remote.example/users/emoji_actor"

      assert {:ok, account} =
               SukhiFedi.Federation.RemoteAccounts.upsert_from_actor_json(%{
                 "id" => actor_uri,
                 "preferredUsername" => "emoji_actor",
                 "name" => "Nyaa :heart:",
                 "summary" => "bio with :blobcat:",
                 "inbox" => "https://remote.example/users/emoji_actor/inbox",
                 "tag" => [
                   %{
                     "type" => "Emoji",
                     "name" => ":heart:",
                     "icon" => %{"url" => "https://remote.example/e/heart.png"}
                   },
                   %{
                     "type" => "Emoji",
                     "name" => ":blobcat:",
                     "icon" => %{"url" => "https://remote.example/e/blobcat.png"}
                   }
                 ]
               })

      shortcodes = Enum.map(account.emojis, & &1["shortcode"])
      assert "heart" in shortcodes
      assert "blobcat" in shortcodes
    end
  end

  describe "inbound quote notes" do
    test "Create(Note) with quoteUrl mirrors quote_of_ap_id" do
      quoter = create_remote_account!("quoter", "remote.example")
      original = "https://remote.example/notes/original"
      quote_note = "https://remote.example/notes/q1"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => quoter.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => quote_note,
                     "attributedTo" => quoter.actor_uri,
                     "content" => "quoting you",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "quoteUrl" => original
                   }
                 }
               })

      assert %Note{quote_of_ap_id: ^original} = Repo.get_by(Note, ap_id: quote_note)
    end

    test "Create(Note) with a FEP-e232 tag Link mirrors quote_of_ap_id" do
      quoter = create_remote_account!("quoter_fep", "remote.example")
      original = "https://remote.example/notes/fep-original"
      quote_note = "https://remote.example/notes/q2"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => quoter.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => quote_note,
                     "attributedTo" => quoter.actor_uri,
                     "content" => "quoting via FEP-e232",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "tag" => [
                       %{"type" => "Mention", "href" => "https://remote.example/users/someone"},
                       %{
                         "type" => "Link",
                         "mediaType" =>
                           "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
                         "href" => original,
                         "rel" => "https://misskey-hub.net/ns#_misskey_quote"
                       }
                     ]
                   }
                 }
               })

      assert %Note{quote_of_ap_id: ^original} = Repo.get_by(Note, ap_id: quote_note)
    end

    test "Create(Note) with _misskey_content mirrors the MFM source" do
      author = create_remote_account!("mfm_author", "remote.example")
      note_uri = "https://remote.example/notes/mfm1"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "<p>rendered</p>",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "_misskey_content" => "$[jelly MFM] source"
                   }
                 }
               })

      assert %Note{mfm: "$[jelly MFM] source"} = Repo.get_by(Note, ap_id: note_uri)
    end
  end

  describe "inbound mentions" do
    test "a Mention tag for a local user creates a mention notification" do
      mentioned = create_account!("mentioned_local")
      author = create_remote_account!("mention_author", "remote.example")
      note_uri = "https://remote.example/notes/m1"
      local_uri = "https://#{Config.domain!()}/users/#{mentioned.username}"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => author.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => author.actor_uri,
                     "content" => "hey @mentioned_local",
                     "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                     "tag" => [
                       %{"type" => "Mention", "href" => local_uri, "name" => "@mentioned_local"}
                     ]
                   }
                 }
               })

      note = Repo.get_by(Note, ap_id: note_uri)

      assert Repo.get_by(Notification,
               account_id: mentioned.id,
               from_account_id: author.id,
               note_id: note.id,
               type: "mention"
             )
    end
  end

  describe "inbound DMs" do
    test "a received DM is stored under the remote sender, not the recipient" do
      bob = create_account!("bob_dm_in")
      alice = create_remote_account!("alice_remote", "remote.example")
      note_uri = "https://remote.example/notes/dm1"
      bob_uri = "https://#{Config.domain!()}/users/#{bob.username}"

      assert :ok =
               Instructions.execute(%{
                 "action" => "save",
                 "object" => %{
                   "type" => "Create",
                   "actor" => alice.actor_uri,
                   "object" => %{
                     "type" => "Note",
                     "id" => note_uri,
                     "attributedTo" => alice.actor_uri,
                     "content" => "psst, just you",
                     "to" => [bob_uri],
                     "context" => note_uri
                   }
                 }
               })

      note = Repo.get_by(Note, ap_id: note_uri)
      assert note.visibility == "direct"
      # Authored by the remote sender — not the local recipient.
      assert note.account_id == alice.id
      assert note.conversation_ap_id == note_uri

      # Both join the conversation; the recipient is unread, sender is not.
      assert %{unread: true} = participant(note_uri, bob.id)
      assert %{unread: false} = participant(note_uri, alice.id)

      # The recipient's conversation shows the DM, authored by the sender,
      # with the sender as the other account.
      [convo] = Conversations.list(bob.id)
      assert convo.unread == true
      assert convo.last_status.id == note.id
      assert convo.last_status.account_id == alice.id
      assert [%{id: alice_id}] = convo.accounts
      assert alice_id == alice.id
    end

    test "re-delivery of the same DM is idempotent" do
      bob = create_account!("bob_dm_dup")
      alice = create_remote_account!("alice_dup", "remote.example")
      note_uri = "https://remote.example/notes/dmdup"
      bob_uri = "https://#{Config.domain!()}/users/#{bob.username}"

      activity = %{
        "action" => "save",
        "object" => %{
          "type" => "Create",
          "actor" => alice.actor_uri,
          "object" => %{
            "type" => "Note",
            "id" => note_uri,
            "attributedTo" => alice.actor_uri,
            "content" => "twice",
            "to" => [bob_uri],
            "context" => note_uri
          }
        }
      }

      assert :ok = Instructions.execute(activity)
      assert :ok = Instructions.execute(activity)

      assert 1 = Repo.aggregate(from(n in Note, where: n.ap_id == ^note_uri), :count)
    end

    test "a reply with no context threads under the parent's conversation" do
      bob = create_account!("bob_dm_thread")
      alice = create_remote_account!("alice_thread", "remote.example")
      bob_uri = "https://#{Config.domain!()}/users/#{bob.username}"

      root_uri = "https://remote.example/notes/dm_root"
      reply_uri = "https://remote.example/notes/dm_reply"

      # Root DM, threaded under its own id.
      :ok =
        Instructions.execute(%{
          "action" => "save",
          "object" => %{
            "type" => "Create",
            "actor" => alice.actor_uri,
            "object" => %{
              "type" => "Note",
              "id" => root_uri,
              "attributedTo" => alice.actor_uri,
              "content" => "first",
              "to" => [bob_uri],
              "context" => root_uri
            }
          }
        })

      # Reply in_reply_to the root, but carrying NO `context` (Misskey-
      # family servers omit it). It must still join the root's thread
      # rather than open a second conversation under its own id.
      :ok =
        Instructions.execute(%{
          "action" => "save",
          "object" => %{
            "type" => "Create",
            "actor" => alice.actor_uri,
            "object" => %{
              "type" => "Note",
              "id" => reply_uri,
              "attributedTo" => alice.actor_uri,
              "content" => "second",
              "to" => [bob_uri],
              "inReplyTo" => root_uri
            }
          }
        })

      root = Repo.get_by(Note, ap_id: root_uri)
      reply = Repo.get_by(Note, ap_id: reply_uri)
      assert reply.conversation_ap_id == root.conversation_ap_id

      # One conversation for the recipient, not two.
      assert [convo] = Conversations.list(bob.id)
      assert convo.last_status.id == reply.id
    end
  end

  defp participant(conversation_ap_id, account_id) do
    Repo.one(
      from(cp in ConversationParticipant,
        where: cp.conversation_ap_id == ^conversation_ap_id and cp.account_id == ^account_id,
        select: %{unread: cp.unread}
      )
    )
  end

  describe "C1: inbound signer→actor binding" do
    test "Create from a signer on a different host than the actor is dropped" do
      author = create_remote_account!("c1_author", "remote.example")
      note_uri = "https://remote.example/notes/c1-forged"

      activity = %{
        "type" => "Create",
        "actor" => author.actor_uri,
        "object" => %{
          "type" => "Note",
          "id" => note_uri,
          "attributedTo" => author.actor_uri,
          "content" => "forwarded forgery",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      # Signer evil.example ≠ actor host remote.example → untrusted, not mirrored.
      assert :ok =
               Instructions.execute(%{"action" => "save", "object" => activity}, "evil.example")

      refute Repo.get_by(Note, ap_id: note_uri)

      # Same activity, signer host matches the actor → mirrored.
      assert :ok =
               Instructions.execute(%{"action" => "save", "object" => activity}, "remote.example")

      assert Repo.get_by(Note, ap_id: note_uri)
    end

    test "Create whose note id host differs from its author is rejected even with a matching signer" do
      author = create_remote_account!("c1_idspoof", "remote.example")

      activity = %{
        "type" => "Create",
        "actor" => author.actor_uri,
        "object" => %{
          "type" => "Note",
          "id" => "https://victim.example/notes/spoof",
          "attributedTo" => author.actor_uri,
          "content" => "id on a foreign host",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok =
               Instructions.execute(%{"action" => "save", "object" => activity}, "remote.example")

      refute Repo.get_by(Note, ap_id: "https://victim.example/notes/spoof")
    end

    test "Delete only removes a note whose id is on the actor's own host" do
      victim = create_remote_account!("c1_victim", "victim.example")
      victim_note = "https://victim.example/notes/keep"

      :ok =
        Instructions.execute(
          %{
            "action" => "save",
            "object" => %{
              "type" => "Create",
              "actor" => victim.actor_uri,
              "object" => %{
                "type" => "Note",
                "id" => victim_note,
                "attributedTo" => victim.actor_uri,
                "content" => "victim's post",
                "to" => ["https://www.w3.org/ns/activitystreams#Public"]
              }
            }
          },
          "victim.example"
        )

      assert Repo.get_by(Note, ap_id: victim_note)

      # An attacker validly signed for its own host cannot delete another
      # origin's note.
      assert :ok =
               Instructions.execute(
                 %{
                   "action" => "save",
                   "object" => %{
                     "type" => "Delete",
                     "actor" => "https://evil.example/users/attacker",
                     "object" => victim_note
                   }
                 },
                 "evil.example"
               )

      assert Repo.get_by(Note, ap_id: victim_note),
             "cross-origin Delete must not remove the note"

      # The real origin can delete its own note.
      assert :ok =
               Instructions.execute(
                 %{
                   "action" => "save",
                   "object" => %{
                     "type" => "Delete",
                     "actor" => victim.actor_uri,
                     "object" => victim_note
                   }
                 },
                 "victim.example"
               )

      refute Repo.get_by(Note, ap_id: victim_note)
    end
  end

  # A local note carries no `ap_id`; its AP id is synthesized the same
  # way `NoteController` publishes it.
  defp local_note_uri(%Account{username: u}, %{id: id}) do
    "https://#{Config.domain!()}/users/#{u}/notes/#{id}"
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end

  defp create_remote_account!(username, domain) do
    %Account{
      username: username,
      display_name: username,
      summary: "",
      domain: domain,
      actor_uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/users/#{username}/inbox"
    }
    |> insert_account!()
  end
end

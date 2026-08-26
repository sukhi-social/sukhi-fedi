# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.BuildersTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Fedi.{Builders, LdSignature, Oip}
  alias SukhiFedi.FediGolden

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  defp creds do
    %{"privateKeyJwk" => FediGolden.private_key_jwk(), "keyId" => FediGolden.key_id()}
  end

  defp ed25519_creds do
    %{
      "ed25519PrivateKeyJwk" => FediGolden.oip()["privateKeyJwk"],
      "ed25519KeyId" => FediGolden.oip()["keyId"]
    }
  end

  defp build!(type, payload) do
    {:ok, result} = Builders.build(type, Map.merge(creds(), payload))
    result
  end

  describe "題つきの投稿" do
    defp titled!(extra \\ %{}) do
      build!(
        "note",
        Map.merge(
          %{
            "actor" => FediGolden.actor(),
            "content" => "<p>本文</p>",
            "recipientInboxes" => ["https://remote.test/inbox"],
            "noteId" => "https://sukhi.test/notes/1",
            "activityId" => "https://sukhi.test/notes/1/activity",
            "title" => "寝過ぎた",
            "authorHandle" => "@hinata@sukhi.test",
            "authorUri" => "https://sukhi.test/users/hinata"
          },
          extra
        )
      )["note"]["object"]
    end

    test "題は `name` に載る ── 掲示板を持つ実装はここを読む" do
      assert titled!()["name"] == "寝過ぎた"
    end

    test "本文の頭に「題 — @書いた人」を引用で置く" do
      content = titled!()["content"]

      assert content =~ "<blockquote>"
      assert content =~ "寝過ぎた"
      assert content =~ "@hinata@sukhi.test"
      assert content =~ "https://sukhi.test/users/hinata"
      # 本文そのものは、そのあとに続く。
      assert content =~ "<p>本文</p>"
      assert String.starts_with?(content, "<blockquote>")
    end

    test "書いた人は本物の Mention ── ただの文字だと、押しても誰にも行き着かない" do
      tags = titled!()["tag"] || []

      assert Enum.any?(tags, fn t ->
               t["type"] == "Mention" and t["href"] == "https://sukhi.test/users/hinata" and
                 t["name"] == "@hinata@sukhi.test"
             end)
    end

    test "題の中の記号は escape される" do
      content = titled!(%{"title" => ~s(<script>"x"&y)})["content"]

      refute content =~ "<script>"
      assert content =~ "&lt;script&gt;"
      assert content =~ "&amp;y"
    end

    test "audience はどの板かを名乗る ── `to` には入れない" do
      object = titled!(%{"audience" => "https://sukhi.test/users/hinata-deco"})

      assert object["audience"] == "https://sukhi.test/users/hinata-deco"
      # `to` に入れると Mastodon が板を silent mention として解決する。
      refute "https://sukhi.test/users/hinata-deco" in List.wrap(object["to"])
      refute "https://sukhi.test/users/hinata-deco" in List.wrap(object["cc"])
    end

    test "表札の無い板は audience を持たない" do
      refute Map.has_key?(titled!(), "audience")
    end

    test "既定は Note ── 選ばなければ本文が外でも読める" do
      assert titled!()["type"] == "Note"
      refute Map.has_key?(titled!(), "summary")
    end

    test "選べば Article ── 意味の上では題を持つものの型" do
      object = titled!(%{"asArticle" => true})

      assert object["type"] == "Article"
      assert object["name"] == "寝過ぎた"
    end

    test "Article には書き出しを添える ── 無いと題とリンクだけになる" do
      object = titled!(%{"asArticle" => true, "content" => "<p>ながい はなし</p>"})

      # Mastodon は Article の content を出さず、題・summary・リンクを
      # 並べる。summary が空だと、外の人には何も届かない。
      assert object["summary"] =~ "ながい はなし"
      refute object["summary"] =~ "<p>"
    end

    test "自分で書いた CW は、抜粋で上書きしない" do
      object = titled!(%{"asArticle" => true, "summary" => "しんどい話です"})
      assert object["summary"] == "しんどい話です"
    end

    test "題が無ければ Article にはならない ── 話す板は素の Note" do
      assert titled!(%{"asArticle" => true, "title" => nil})["type"] == "Note"
    end

    test "題が無ければ、何も足さない ── 話す板の投稿は素のまま" do
      object = titled!(%{"title" => nil})

      refute Map.has_key?(object, "name")
      assert object["content"] == "<p>本文</p>"
      refute Enum.any?(object["tag"] || [], &(&1["type"] == "Mention"))
    end
  end

  test "note: audience, injections, signature, envelope" do
    result =
      build!("note", %{
        "actor" => FediGolden.actor(),
        "content" => "<p>hello</p>",
        "recipientInboxes" => ["https://remote.test/inbox"],
        "noteId" => "https://sukhi.test/notes/1",
        "activityId" => "https://sukhi.test/notes/1/activity",
        "quoteUrl" => "https://remote.test/notes/9",
        "inReplyToId" => "https://remote.test/notes/8",
        "attachments" => [
          %{"url" => "https://media.sukhi.test/1.webp", "mediaType" => "image/webp", "width" => 800}
        ]
      })

    assert result["recipientInboxes"] == ["https://remote.test/inbox"]
    activity = result["note"]

    assert activity["type"] == "Create"
    assert activity["to"] == [@as_public]
    assert activity["cc"] == [FediGolden.actor() <> "/followers"]
    assert activity["signature"]["type"] == "RsaSignature2017"

    object = activity["object"]
    assert object["type"] == "Note"
    assert object["inReplyTo"] == "https://remote.test/notes/8"
    assert object["_misskey_content"] == "<p>hello</p>"
    assert object["quoteUrl"] == "https://remote.test/notes/9"
    assert object["_misskey_quote"] == "https://remote.test/notes/9"
    # FEP-044f canonical quote (signed) rides alongside the aliases, and
    # the note advertises that anyone may quote it with auto-approval.
    assert object["quote"] == "https://remote.test/notes/9"
    assert object["interactionPolicy"] == %{"canQuote" => %{"automaticApproval" => [@as_public]}}

    assert [%{"type" => "Link", "rel" => "https://misskey-hub.net/ns#_misskey_quote"}] =
             object["tag"]

    assert [%{"type" => "Document", "url" => "https://media.sukhi.test/1.webp", "width" => 800} = doc] =
             object["attachment"]

    refute Map.has_key?(doc, "name")
  end

  test "note: carries the author's content warning and sensitive flag" do
    object =
      build!("note", %{
        "actor" => FediGolden.actor(),
        "content" => "<p>spoiler body</p>",
        "summary" => "cw: spoilers",
        "sensitive" => true,
        "recipientInboxes" => [],
        "noteId" => "https://sukhi.test/notes/2",
        "activityId" => "https://sukhi.test/notes/2/activity"
      })["note"]["object"]

    assert object["summary"] == "cw: spoilers"
    assert object["sensitive"] == true
  end

  test "note: omits summary/sensitive when the author set neither" do
    object =
      build!("note", %{
        "actor" => FediGolden.actor(),
        "content" => "<p>plain</p>",
        "recipientInboxes" => [],
        "noteId" => "https://sukhi.test/notes/3",
        "activityId" => "https://sukhi.test/notes/3/activity"
      })["note"]["object"]

    refute Map.has_key?(object, "summary")
    refute Map.has_key?(object, "sensitive")
  end

  test "vote: a Create(Note) ballot — name = option, inReplyTo = Question, to = author" do
    result =
      build!("vote", %{
        "actor" => FediGolden.actor(),
        "name" => "Option A",
        "inReplyTo" => "https://remote.test/notes/poll1",
        "to" => ["https://remote.test/users/pollster"],
        "noteId" => "#{FediGolden.actor()}/poll-votes/5-7",
        "activityId" => "#{FediGolden.actor()}/poll-votes/5-7/activity",
        "recipientInboxes" => ["https://remote.test/users/pollster/inbox"]
      })

    assert result["recipientInboxes"] == ["https://remote.test/users/pollster/inbox"]
    activity = result["note"]
    assert activity["type"] == "Create"
    assert activity["to"] == ["https://remote.test/users/pollster"]

    object = activity["object"]
    assert object["type"] == "Note"
    assert object["name"] == "Option A"
    assert object["inReplyTo"] == "https://remote.test/notes/poll1"
    # A ballot carries no body.
    refute Map.has_key?(object, "content")
  end

  test "follow: LD signature round-trips through our verifier" do
    result =
      build!("follow", %{
        "actor" => FediGolden.actor(),
        "object" => "https://remote.test/users/friend",
        "activityId" => "https://sukhi.test/follows/1"
      })

    follow = result["follow"]
    assert follow["type"] == "Follow"
    # No post-sign injections on Follow, so the signature must hold.
    assert :ok = LdSignature.verify(follow, FediGolden.public_key())
  end

  test "quote_request: FEP-044f shape, LD signature round-trips" do
    result =
      build!("quote_request", %{
        "actor" => FediGolden.actor(),
        "object" => "https://remote.test/users/alice/notes/1",
        "instrument" => "https://sukhi.test/users/shiro/notes/7",
        "activityId" => "https://sukhi.test/users/shiro/notes/7/quote-request"
      })

    qr = result["quoteRequest"]
    assert qr["type"] == "QuoteRequest"
    # object = the post we quote; instrument = our quote post (by URI).
    assert qr["object"] == "https://remote.test/users/alice/notes/1"
    assert qr["instrument"] == "https://sukhi.test/users/shiro/notes/7"
    # No post-sign injections on a QuoteRequest, so the signature holds.
    assert :ok = LdSignature.verify(qr, FediGolden.public_key())
  end

  test "update: Update(Note) re-delivers the quote + authorization; proof covers them" do
    result =
      build!(
        "update",
        Map.merge(ed25519_creds(), %{
          "actor" => FediGolden.actor(),
          "content" => "<p>quoting</p>",
          "recipientInboxes" => [],
          "noteId" => "https://sukhi.test/notes/5",
          "activityId" => "https://sukhi.test/notes/5#update-quote-auth",
          "quoteUrl" => "https://remote.test/notes/1",
          "quoteAuthorization" => "https://remote.test/users/a/quote-auth/3"
        })
      )

    update = result["update"]
    assert update["type"] == "Update"

    object = update["object"]
    assert object["type"] == "Note"
    assert Map.has_key?(object, "updated")
    assert object["quote"] == "https://remote.test/notes/1"
    assert object["quoteUrl"] == "https://remote.test/notes/1"
    assert object["quoteAuthorization"] == "https://remote.test/users/a/quote-auth/3"
    # The proof attaches after the injections, so it covers the delivered doc.
    assert :ok = Oip.verify(update, FediGolden.oip_public_key())
  end

  test "emoji_react: Like with content and Emoji tag" do
    result =
      build!("emoji_react", %{
        "actor" => FediGolden.actor(),
        "object" => "https://remote.test/notes/9",
        "content" => ":blobcat:",
        "tag" => %{"name" => ":blobcat:", "url" => "https://sukhi.test/emoji/blobcat.png"},
        "activityId" => "https://sukhi.test/likes/2",
        "recipientInboxes" => []
      })

    like = result["emojiReact"]
    assert like["type"] == "Like"
    assert like["content"] == ":blobcat:"

    assert [%{"type" => "Emoji", "name" => ":blobcat:", "icon" => %{"type" => "Image", "url" => url}}] =
             like["tag"]

    assert url == "https://sukhi.test/emoji/blobcat.png"
  end

  test "emoji_react without tag: plain unicode reaction" do
    result =
      build!("emoji_react", %{
        "actor" => FediGolden.actor(),
        "object" => "https://remote.test/notes/9",
        "content" => "⭐",
        "activityId" => "https://sukhi.test/likes/3",
        "recipientInboxes" => []
      })

    refute Map.has_key?(result["emojiReact"], "tag")
  end

  test "undo: audience mirrors the inner object" do
    result =
      build!("undo", %{
        "actor" => FediGolden.actor(),
        "activityId" => "https://sukhi.test/undos/1",
        "recipientInboxes" => [],
        "inner" => %{
          "type" => "Like",
          "id" => "https://sukhi.test/likes/1",
          "object" => "https://remote.test/notes/9"
        }
      })

    undo = result["undo"]
    assert undo["to"] == ["https://remote.test/notes/9"]
    assert undo["object"]["type"] == "Like"
    assert undo["object"]["id"] == "https://sukhi.test/likes/1"
  end

  test "delete: Tombstone object, public audience" do
    result =
      build!("delete", %{
        "actor" => FediGolden.actor(),
        "activityId" => "https://sukhi.test/deletes/1",
        "objectId" => "https://sukhi.test/notes/1",
        "recipientInboxes" => []
      })

    del = result["delete"]
    assert del["object"] == %{"id" => "https://sukhi.test/notes/1", "type" => "Tombstone"}
    assert del["to"] == [@as_public]
  end

  test "add/remove: collection ops carry object and target" do
    for {type, ap_type} <- [{"add", "Add"}, {"remove", "Remove"}] do
      result =
        build!(type, %{
          "actor" => FediGolden.actor(),
          "objectUri" => "https://sukhi.test/notes/1",
          "targetUri" => FediGolden.actor() <> "/collections/featured",
          "activityId" => "https://sukhi.test/#{type}s/1",
          "recipientInboxes" => []
        })

      assert result["activity"]["type"] == ap_type
      assert result["activity"]["target"] == FediGolden.actor() <> "/collections/featured"
    end
  end

  test "dm: direct audience, conversation context, no quote injection" do
    result =
      build!("dm", %{
        "actor" => FediGolden.actor(),
        "content" => "<p>psst</p>",
        "recipientActors" => ["https://remote.test/users/friend"],
        "noteId" => "https://sukhi.test/notes/2",
        "activityId" => "https://sukhi.test/notes/2/activity",
        "recipientInboxes" => ["https://remote.test/users/friend/inbox"],
        "conversationId" => "https://sukhi.test/contexts/1"
      })

    activity = result["note"]
    assert activity["to"] == ["https://remote.test/users/friend"]
    assert activity["cc"] == []
    assert activity["object"]["context"] == "https://sukhi.test/contexts/1"
    refute Map.has_key?(activity["object"], "quoteUrl")
  end

  test "unknown object_type is an error, same wording as the Bun dispatcher" do
    assert {:error, "unknown object_type: nope"} = Builders.build("nope", %{})
  end

  describe "FEP-8b32 proof on outbound activities" do
    test "note: proof lands after the injections and covers them" do
      result =
        build!(
          "note",
          Map.merge(ed25519_creds(), %{
            "actor" => FediGolden.actor(),
            "content" => "<p>hello</p>",
            "recipientInboxes" => [],
            "noteId" => "https://sukhi.test/notes/1",
            "activityId" => "https://sukhi.test/notes/1/activity",
            "quoteUrl" => "https://remote.test/notes/9",
            "attachments" => [%{"url" => "https://media.sukhi.test/1.webp"}]
          })
        )

      note = result["note"]
      assert note["signature"]["type"] == "RsaSignature2017"
      assert note["proof"]["cryptosuite"] == "eddsa-jcs-2022"
      assert note["proof"]["verificationMethod"] == FediGolden.oip()["keyId"]
      # The proof must verify over the document as delivered — extras
      # included; a receiver strips only `proof` and `signature`.
      assert :ok = Oip.verify(note, FediGolden.oip_public_key())
      assert note["object"]["_misskey_content"] == "<p>hello</p>"
    end

    test "follow: proof rides alongside the LD signature" do
      result =
        build!(
          "follow",
          Map.merge(ed25519_creds(), %{
            "actor" => FediGolden.actor(),
            "object" => "https://remote.test/users/friend",
            "activityId" => "https://sukhi.test/follows/1"
          })
        )

      follow = result["follow"]
      assert :ok = LdSignature.verify(follow, FediGolden.public_key())
      assert :ok = Oip.verify(follow, FediGolden.oip_public_key())
    end

    test "no Ed25519 key in the payload → no proof, RSA only (pre-backfill rows)" do
      result =
        build!("follow", %{
          "actor" => FediGolden.actor(),
          "object" => "https://remote.test/users/friend",
          "activityId" => "https://sukhi.test/follows/1"
        })

      refute Map.has_key?(result["follow"], "proof")
      assert result["follow"]["signature"]["type"] == "RsaSignature2017"
    end

    test "an unreadable Ed25519 key is an error, not a silent downgrade" do
      payload = %{
        "actor" => FediGolden.actor(),
        "object" => "https://remote.test/users/friend",
        "activityId" => "https://sukhi.test/follows/1",
        "ed25519PrivateKeyJwk" => %{"kty" => "OKP", "crv" => "Ed25519", "d" => "broken"},
        "ed25519KeyId" => FediGolden.oip()["keyId"]
      }

      assert {:error, :invalid_jwk} = Builders.build("follow", Map.merge(creds(), payload))
    end
  end
end

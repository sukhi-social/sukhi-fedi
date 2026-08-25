# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.ActorJsonTest do
  # Parity-with-delivery test. The shape contract checked here must
  # match `SukhiDelivery.AP.ActorJsonTest` line-for-line; if you add a
  # field on one side, add it here too, otherwise federated peers will
  # see a different actor JSON depending on which node served it.
  use ExUnit.Case, async: false

  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.Schema.Account

  @expected_top_keys ~w(
    @context id type url preferredUsername name summary inbox outbox
    followers following featured manuallyApprovesFollowers
    discoverable indexable pendingFollowers pendingFollowing endpoints
    publicKey assertionMethod icon image
  )

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, "test.example")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)
    :ok
  end

  test "build_person/1 emits the contracted shape" do
    account = %Account{
      username: "alice",
      display_name: "Alice",
      summary: "hello",
      public_key_pem: "PEM",
      ed25519_public_multibase: "z6MkExample",
      avatar_url: "https://cdn.example/a.png",
      banner_url: "https://cdn.example/b.jpg",
      locked: true,
      discoverable: true,
      indexable: true
    }

    person = ActorJson.build_person(account)

    assert MapSet.new(Map.keys(person)) == MapSet.new(@expected_top_keys)
    assert person["id"] == "https://test.example/users/alice"

    # 人が読む頁のありか。`id` とは別もので、これが無いと受け取った側は
    # 「プロフィールを開く」の行き先を作れない。
    assert person["url"] == "https://test.example/@alice"
    assert person["type"] == "Person"
    assert person["manuallyApprovesFollowers"] == true
    assert person["discoverable"] == true
    assert person["indexable"] == true
    # Locked → FEP-4ccd pending collections are advertised.
    assert person["pendingFollowers"] == "https://test.example/users/alice/pendingFollowers"
    assert person["pendingFollowing"] == "https://test.example/users/alice/pendingFollowing"
    assert person["endpoints"] == %{"sharedInbox" => "https://test.example/inbox"}

    assert MapSet.new(Map.keys(person["publicKey"])) ==
             MapSet.new(~w(id owner publicKeyPem))

    assert person["assertionMethod"] == [
             %{
               "id" => "https://test.example/users/alice#ed25519-key",
               "type" => "Multikey",
               "controller" => "https://test.example/users/alice",
               "publicKeyMultibase" => "z6MkExample"
             }
           ]

    for key <- ~w(icon image) do
      assert MapSet.new(Map.keys(person[key])) == MapSet.new(~w(type mediaType url))
      assert person[key]["type"] == "Image"
    end
  end

  test "build_person/1 omits icon/image when avatar/banner are blank" do
    account = %Account{username: "bob", public_key_pem: "PEM"}
    person = ActorJson.build_person(account)
    refute Map.has_key?(person, "icon")
    refute Map.has_key?(person, "image")
    # No Ed25519 key minted yet (pre-backfill row) → no assertionMethod.
    refute Map.has_key?(person, "assertionMethod")
    assert person["manuallyApprovesFollowers"] == false
    # Search-indexing consent defaults to false — opt-in, never assumed.
    assert person["discoverable"] == false
    assert person["indexable"] == false
    # Unlocked → no pending collections (auto-accept never queues followers).
    refute Map.has_key?(person, "pendingFollowers")
    refute Map.has_key?(person, "pendingFollowing")
    # No fields → no attachment, so a bare actor stays bare.
    refute Map.has_key?(person, "attachment")
  end

  test "build_person/1 emits fields as attachment PropertyValue rows" do
    account = %Account{
      username: "carol",
      public_key_pem: "PEM",
      fields: [%{"name" => "site", "value" => "<a href=\"https://x\">x</a>"}]
    }

    person = ActorJson.build_person(account)

    assert person["attachment"] == [
             %{
               "type" => "PropertyValue",
               "name" => "site",
               "value" => "<a href=\"https://x\">x</a>"
             }
           ]
  end

  test "build_person/1 emits alsoKnownAs / movedTo only when set" do
    bare = ActorJson.build_person(%Account{username: "dave", public_key_pem: "PEM"})
    refute Map.has_key?(bare, "alsoKnownAs")
    refute Map.has_key?(bare, "movedTo")

    migrating =
      ActorJson.build_person(%Account{
        username: "erin",
        public_key_pem: "PEM",
        aliases: ["https://old.example/users/erin"],
        moved_to_uri: "https://new.example/users/erin"
      })

    assert migrating["alsoKnownAs"] == ["https://old.example/users/erin"]
    assert migrating["movedTo"] == "https://new.example/users/erin"
  end

  test "actor_uri/1 accepts a struct or a username" do
    assert ActorJson.actor_uri("alice") == "https://test.example/users/alice"
    assert ActorJson.actor_uri(%Account{username: "alice"}) ==
             "https://test.example/users/alice"
  end
end

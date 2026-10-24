defmodule SukhiShared.ActorJsonTest do
  use ExUnit.Case, async: true

  alias SukhiShared.ActorJson

  # Only the fields ActorJson reads; either app's Account struct has them.
  defp account(attrs \\ %{}) do
    Map.merge(
      %{
        username: "alice",
        display_name: nil,
        summary: nil,
        locked: false,
        discoverable: true,
        indexable: false,
        public_key_pem: "PEM",
        ed25519_public_multibase: nil,
        avatar_url: nil,
        banner_url: nil,
        fields: [],
        aliases: [],
        moved_to_uri: nil
      },
      attrs
    )
  end

  test "uris take the domain they are given, from a map or a username" do
    assert ActorJson.actor_uri("a.example", "alice") == "https://a.example/users/alice"
    assert ActorJson.actor_uri("a.example", account()) == "https://a.example/users/alice"
    assert ActorJson.profile_uri("b.example", account()) == "https://b.example/@alice"
  end

  test "build_person keeps a bare actor bare, and adds the optional keys when set" do
    bare = ActorJson.build_person("a.example", account())
    assert bare["id"] == "https://a.example/users/alice"
    assert bare["endpoints"]["sharedInbox"] == "https://a.example/inbox"
    assert bare["name"] == "alice"
    refute Map.has_key?(bare, "icon")
    refute Map.has_key?(bare, "pendingFollowers")
    refute Map.has_key?(bare, "movedTo")

    full =
      ActorJson.build_person(
        "a.example",
        account(%{
          locked: true,
          avatar_url: "https://x/a.PNG",
          aliases: ["https://old/u/a"],
          moved_to_uri: "https://new/u/a",
          ed25519_public_multibase: "z6Mk"
        })
      )

    assert full["icon"]["mediaType"] == "image/png"
    assert full["pendingFollowers"] == "https://a.example/users/alice/pendingFollowers"
    assert full["alsoKnownAs"] == ["https://old/u/a"]
    assert full["movedTo"] == "https://new/u/a"
    assert [%{"type" => "Multikey"}] = full["assertionMethod"]
  end

  test "the custom emoji a profile wears ride as AP Emoji tags" do
    emojis = [
      %{"shortcode" => "blobcat", "url" => "https://a.example/blobcat.png"},
      %{"shortcode" => "nourl", "url" => nil}
    ]

    p = ActorJson.build_person("a.example", account(%{emojis: emojis}))

    assert [%{"type" => "Emoji", "name" => ":blobcat:", "icon" => %{"url" => "https://a.example/blobcat.png"}}] =
             p["tag"]

    refute Map.has_key?(ActorJson.build_person("a.example", account()), "tag")
  end

  test "build_update wraps the person for followers" do
    u = ActorJson.build_update("a.example", account())
    assert u["type"] == "Update"
    assert u["cc"] == ["https://a.example/users/alice/followers"]
    assert u["object"]["id"] == u["actor"]
  end
end

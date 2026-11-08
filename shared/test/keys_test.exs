# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.KeysTest do
  use ExUnit.Case, async: true

  alias SukhiShared.{ActorJson, Keys}

  @actor "https://a.example/users/alice"

  test "the key ids are the actor id plus a fixed fragment" do
    assert Keys.main_key_id(@actor) == @actor <> "#main-key"
    assert Keys.ed25519_key_id(@actor) == @actor <> "#ed25519-key"
  end

  test "the ids the actor document publishes are the ids signatures name" do
    actor = ActorJson.build_person("a.example", account())

    assert actor["publicKey"]["id"] == Keys.main_key_id(@actor)
    assert [%{"id" => id}] = actor["assertionMethod"]
    assert id == Keys.ed25519_key_id(@actor)
  end

  defp account do
    %{
      username: "alice",
      display_name: nil,
      summary: nil,
      locked: false,
      discoverable: true,
      indexable: false,
      public_key_pem: "PEM",
      ed25519_public_multibase: "z6Mkexample",
      avatar_url: nil,
      banner_url: nil,
      fields: [],
      aliases: [],
      moved_to_uri: nil
    }
  end
end

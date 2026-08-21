# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.GroupJsonTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.AP.GroupJson
  alias SukhiFedi.Schema.Deco

  @expected_top_keys ~w(
    @context id type url preferredUsername name summary inbox outbox
    followers manuallyApprovesFollowers discoverable indexable
    endpoints publicKey
  )

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, "test.example")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)
    :ok
  end

  test "build_group/1 emits the contracted shape" do
    deco = %Deco{
      slug: "hinata",
      name: "ひなた",
      description: "あたたかい板",
      public_key_pem: "PEM"
    }

    group = GroupJson.build_group(deco)

    assert MapSet.new(Map.keys(group)) == MapSet.new(@expected_top_keys)
    assert group["id"] == "https://test.example/users/hinata-deco"
    assert group["type"] == "Group"
    assert group["url"] == "https://test.example/d/hinata"
    assert group["preferredUsername"] == "hinata-deco"
    assert group["name"] == "ひなた"
    assert group["summary"] == "あたたかい板"
    assert group["inbox"] == "https://test.example/users/hinata-deco/inbox"
    assert group["outbox"] == "https://test.example/users/hinata-deco/outbox"
    assert group["followers"] == "https://test.example/users/hinata-deco/followers"
    # 板は誰でも読める・誰でもフォローできる ── ロックしない。
    assert group["manuallyApprovesFollowers"] == false
    assert group["discoverable"] == true
    assert group["indexable"] == true
    assert group["endpoints"] == %{"sharedInbox" => "https://test.example/inbox"}

    assert MapSet.new(Map.keys(group["publicKey"])) ==
             MapSet.new(~w(id owner publicKeyPem))
  end

  test "build_group/1 blanks description and key when unset" do
    group = GroupJson.build_group(%Deco{slug: "empty", name: "からっぽ"})

    assert group["summary"] == ""
    assert group["publicKey"]["publicKeyPem"] == ""
    refute Map.has_key?(group, "assertionMethod")
  end

  test "build_group/1 emits assertionMethod when an Ed25519 key is set" do
    group =
      GroupJson.build_group(%Deco{
        slug: "hinata",
        name: "ひなた",
        ed25519_public_multibase: "z6MkExample"
      })

    assert group["assertionMethod"] == [
             %{
               "id" => "https://test.example/users/hinata-deco#ed25519-key",
               "type" => "Multikey",
               "controller" => "https://test.example/users/hinata-deco",
               "publicKeyMultibase" => "z6MkExample"
             }
           ]
  end

  test "actor_uri/1 and deco_username/1 accept a struct or a slug" do
    assert GroupJson.actor_uri("hinata") == "https://test.example/users/hinata-deco"
    assert GroupJson.actor_uri(%Deco{slug: "hinata"}) == "https://test.example/users/hinata-deco"
    assert GroupJson.deco_username("hinata") == "hinata-deco"
    assert GroupJson.deco_username(%Deco{slug: "hinata"}) == "hinata-deco"
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.CapabilityTest do
  use ExUnit.Case, async: false

  alias SukhiShared.{ActorJson, Capability}

  setup do
    on_exit(fn -> Application.delete_env(:sukhi_shared, :pull_federation) end)
  end

  test "an actor advertises Pull Federation under generator.implements (FEP-844e)" do
    %{"generator" => gen} = actor = ActorJson.build_person("a.example", account())
    assert gen["type"] == "Application"
    assert [%{"href" => href, "name" => _}] = gen["implements"]
    assert href == Capability.pull_federation()
    assert Capability.context() in actor["@context"]
    assert Capability.declares?(actor, Capability.pull_federation())
  end

  test "an actor publishes where to notify and pull, in endpoints" do
    actor = ActorJson.build_person("a.example", account())
    assert actor["endpoints"]["sharedInbox"] == "https://a.example/inbox"
    assert actor["endpoints"]["pullNotify"] == "https://a.example/pull/v1/notify"
    assert actor["endpoints"]["pullStream"] == "https://a.example/pull/v1/stream"

    assert Capability.pull_endpoints(actor) ==
             {"https://a.example/pull/v1/notify", "https://a.example/pull/v1/stream"}
  end

  test "switched off, the actor stays bare" do
    Application.put_env(:sukhi_shared, :pull_federation, false)
    actor = ActorJson.build_person("a.example", account())
    refute Map.has_key?(actor, "generator")
    assert actor["endpoints"] == %{"sharedInbox" => "https://a.example/inbox"}
  end

  test "hrefs reads the shapes peers send and skips the rest" do
    h = "https://x.example/spec"

    assert Capability.hrefs(%{"generator" => %{"implements" => [%{"href" => h, "name" => "n"}]}}) ==
             [h]

    assert Capability.hrefs(%{"generator" => [%{"implements" => %{"href" => h}}]}) == [h]
    assert Capability.hrefs(%{"generator" => %{"implements" => [h, h]}}) == [h]
    assert Capability.hrefs(%{"generator" => "https://x.example/app"}) == []
    assert Capability.hrefs(%{"generator" => %{"implements" => [%{"href" => 1}, nil, 3]}}) == []
    assert Capability.hrefs(%{}) == []
    assert Capability.hrefs(nil) == []
  end

  test "a hostile list is capped" do
    entries = for i <- 1..500, do: %{"href" => "https://x.example/#{i}"}
    assert length(Capability.hrefs(%{"generator" => %{"implements" => entries}})) == 64

    assert Capability.hrefs(%{
             "generator" => %{"implements" => [%{"href" => String.duplicate("a", 600)}]}
           }) == []
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
      ed25519_public_multibase: nil,
      avatar_url: nil,
      banner_url: nil,
      fields: [],
      aliases: [],
      moved_to_uri: nil
    }
  end
end

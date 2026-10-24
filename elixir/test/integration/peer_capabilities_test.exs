# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PeerCapabilitiesTest do
  use SukhiFedi.IntegrationCase, async: false
  @moduletag :integration

  alias SukhiFedi.Federation.RemoteAccounts
  alias SukhiShared.{Capability, PeerCapabilities}

  defp actor(host, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "https://#{host}/users/bob",
        "type" => "Person",
        "preferredUsername" => "bob",
        "inbox" => "https://#{host}/users/bob/inbox"
      },
      extra
    )
  end

  defp declaring(href \\ Capability.pull_federation()),
    do: %{"generator" => %{"type" => "Application", "implements" => [%{"href" => href}]}}

  test "fetching an actor that declares Pull Federation makes its host capable" do
    {:ok, _} = RemoteAccounts.upsert_from_actor_json(actor("pull.example", declaring()))
    {:ok, _} = RemoteAccounts.upsert_from_actor_json(actor("plain.example"))

    capable =
      PeerCapabilities.capable_hosts(Repo, ["pull.example", "plain.example", "never.example"])

    assert capable == MapSet.new(["pull.example"])
  end

  test "the newest document wins: a host that stops declaring stops being capable" do
    {:ok, _} = RemoteAccounts.upsert_from_actor_json(actor("flip.example", declaring()))
    assert PeerCapabilities.capable?(Repo, "flip.example")

    PeerCapabilities.learn(
      Repo,
      actor("flip.example"),
      DateTime.add(DateTime.utc_now(), 2, :hour)
    )

    refute PeerCapabilities.capable?(Repo, "flip.example")
  end

  test "a sighting older than the freshness window no longer counts" do
    old = DateTime.add(DateTime.utc_now(), -(PeerCapabilities.fresh_days() + 1) * 86_400, :second)
    PeerCapabilities.learn(Repo, actor("old.example", declaring()), old)
    refute PeerCapabilities.capable?(Repo, "old.example")
  end

  test "another capability does not make a host pull-capable" do
    PeerCapabilities.learn(
      Repo,
      actor("rfc.example", declaring("https://datatracker.ietf.org/doc/html/rfc9421"))
    )

    refute PeerCapabilities.capable?(Repo, "rfc.example")
  end
end
